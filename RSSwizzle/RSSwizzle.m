//
//  RSSwizzle.m
//  RSSwizzleTests
//
//  Created by Yan Rabovik on 05.09.13.
//
//

#import "RSSwizzle.h"
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

#if !__has_feature(objc_arc)
#error This code needs ARC. Use compiler option -fobjc-arc
#endif

#pragma mark - Block Helpers
#if !defined(NS_BLOCK_ASSERTIONS)

// See http://clang.llvm.org/docs/Block-ABI-Apple.html#high-level
struct TL_Block_literal_1 {
    void *isa; // initialized to &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct Block_descriptor_1 {
        unsigned long int reserved;         // NULL
        unsigned long int size;         // sizeof(struct TL_Block_literal_1)
        // optional helper functions
        void (*copy_helper)(void *dst, void *src);     // IFF (1<<25)
        void (*dispose_helper)(void *src);             // IFF (1<<25)
        // required ABI.2010.3.16
        const char *signature;                         // IFF (1<<30)
    } *descriptor;
    // imported variables
};

enum {
    TL_BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    TL_BLOCK_HAS_CTOR =          (1 << 26), // helpers have C++ code
    TL_BLOCK_IS_GLOBAL =         (1 << 28),
    TL_BLOCK_HAS_STRET =         (1 << 29), // IFF TL_BLOCK_HAS_SIGNATURE
    TL_BLOCK_HAS_SIGNATURE =     (1 << 30),
};
typedef int TL_BlockFlags;

static const char *TL_blockGetType(id block){
    struct TL_Block_literal_1 *blockRef = (__bridge struct TL_Block_literal_1 *)block;
    TL_BlockFlags flags = blockRef->flags;
    
    if (flags & TL_BLOCK_HAS_SIGNATURE) {
        void *signatureLocation = blockRef->descriptor;
        signatureLocation += sizeof(unsigned long int);
        signatureLocation += sizeof(unsigned long int);
        
        if (flags & TL_BLOCK_HAS_COPY_DISPOSE) {
            signatureLocation += sizeof(void(*)(void *dst, void *src));
            signatureLocation += sizeof(void (*)(void *src));
        }
        
        const char *signature = (*(const char **)signatureLocation);
        return signature;
    }
    
    return NULL;
}

static BOOL TL_blockIsCompatibleWithMethodType(id block, const char *methodType){
    
    const char *blockType = TL_blockGetType(block);
    
    NSMethodSignature *blockSignature;
    
    if (0 == strncmp(blockType, (const char *)"@\"", 2)) {
        // Block return type includes class name for id types
        // while methodType does not include.
        // Stripping out return class name.
        char *quotePtr = strchr(blockType+2, '"');
        if (NULL != quotePtr) {
            ++quotePtr;
            char filteredType[strlen(quotePtr) + 2];
            memset(filteredType, 0, sizeof(filteredType));
            *filteredType = '@';
            strncpy(filteredType + 1, quotePtr, sizeof(filteredType) - 2);
            
            blockSignature = [NSMethodSignature signatureWithObjCTypes:filteredType];
        }else{
            return NO;
        }
    }else{
        blockSignature = [NSMethodSignature signatureWithObjCTypes:blockType];
    }
    
    NSMethodSignature *methodSignature =
        [NSMethodSignature signatureWithObjCTypes:methodType];
    
    if (!blockSignature || !methodSignature) {
        return NO;
    }
    
    if (blockSignature.numberOfArguments != methodSignature.numberOfArguments){
        return NO;
    }
    
    if (strcmp(blockSignature.methodReturnType, methodSignature.methodReturnType) != 0) {
        return NO;
    }
    
    for (int i=0; i<methodSignature.numberOfArguments; ++i){
        if (i == 0){
            // self in method, block in block
            if (strcmp([methodSignature getArgumentTypeAtIndex:i], "@") != 0) {
                return NO;
            }
            if (strcmp([blockSignature getArgumentTypeAtIndex:i], "@?") != 0) {
                return NO;
            }
        }else if(i == 1){
            // SEL in method, self in block
            if (strcmp([methodSignature getArgumentTypeAtIndex:i], ":") != 0) {
                return NO;
            }
            if (strncmp([blockSignature getArgumentTypeAtIndex:i], "@", 1) != 0) {
                return NO;
            }
        }else {
            const char *blockSignatureArg = [blockSignature getArgumentTypeAtIndex:i];
            
            if (strncmp(blockSignatureArg, "@?", 2) == 0) {
                // Handle function pointer / block arguments
                blockSignatureArg = "@?";
            }
            else if (strncmp(blockSignatureArg, "@", 1) == 0) {
                blockSignatureArg = "@";
            }
            
            if (strcmp(blockSignatureArg,
                       [methodSignature getArgumentTypeAtIndex:i]) != 0)
            {
                return NO;
            }
        }
    }
    
    return YES;
}

static BOOL TL_blockIsAnImpFactoryBlock(id block){
    const char *blockType = TL_blockGetType(block);
    TL_RSSwizzleImpFactoryBlock dummyFactory = ^id(TL_RSSwizzleInfo *swizzleInfo){
        return nil;
    };
    const char *factoryType = TL_blockGetType(dummyFactory);
    return 0 == strcmp(factoryType, blockType);
}

#endif // NS_BLOCK_ASSERTIONS


#pragma mark - Swizzling

#pragma mark └ TL_RSSwizzleInfo
typedef IMP (^TL_RSSWizzleImpProvider)(void);

@interface TL_RSSwizzleInfo()
@property (nonatomic,copy) TL_RSSWizzleImpProvider impProviderBlock;
@property (nonatomic, readwrite) SEL selector;
@end

@implementation TL_RSSwizzleInfo

-(TL_RSSwizzleOriginalIMP)getOriginalImplementation{
    NSAssert(_impProviderBlock,nil);
    // Casting IMP to TL_RSSwizzleOriginalIMP to force user casting.
    return (TL_RSSwizzleOriginalIMP)_impProviderBlock();
}

@end


#pragma mark └ RSSwizzle
@implementation TL_RSSwizzle

static void TL_swizzle(Class classToSwizzle,
                    SEL selector,
                    TL_RSSwizzleImpFactoryBlock factoryBlock,
                    BOOL skipMethodCheck)
{
    Method method = class_getInstanceMethod(classToSwizzle, selector);
    
    NSCAssert(NULL != method,
              @"Selector %@ not found in %@ methods of class %@.",
              NSStringFromSelector(selector),
              class_isMetaClass(classToSwizzle) ? @"class" : @"instance",
              classToSwizzle);
    
    NSCAssert(TL_blockIsAnImpFactoryBlock(factoryBlock),
             @"Wrong type of implementation factory block.");
    
    __block OSSpinLock lock = OS_SPINLOCK_INIT;
    // To keep things thread-safe, we fill in the originalIMP later,
    // with the result of the class_replaceMethod call below.
    __block IMP originalIMP = NULL;

    // This block will be called by the client to get original implementation and call it.
    TL_RSSWizzleImpProvider originalImpProvider = ^IMP{
        // It's possible that another thread can call the method between the call to
        // class_replaceMethod and its return value being set.
        // So to be sure originalIMP has the right value, we need a lock.
        OSSpinLockLock(&lock);
        IMP imp = originalIMP;
        OSSpinLockUnlock(&lock);
        
        if (NULL == imp){
            // If the class does not implement the method
            // we need to find an implementation in one of the superclasses.
            Class superclass = class_getSuperclass(classToSwizzle);
            imp = method_getImplementation(class_getInstanceMethod(superclass,selector));
        }
        return imp;
    };
    
    TL_RSSwizzleInfo *swizzleInfo = [TL_RSSwizzleInfo new];
    swizzleInfo.selector = selector;
    swizzleInfo.impProviderBlock = originalImpProvider;
    
    // We ask the client for the new implementation block.
    // We pass swizzleInfo as an argument to factory block, so the client can
    // call original implementation from the new implementation.
    id newIMPBlock = factoryBlock(swizzleInfo);
    
    const char *methodType = method_getTypeEncoding(method);

    if (!skipMethodCheck) {
        NSCAssert(TL_blockIsCompatibleWithMethodType(newIMPBlock,methodType),
                 @"Block returned from factory is not compatible with method type.");
    }
    
    IMP newIMP = imp_implementationWithBlock(newIMPBlock);
    
    // Atomically replace the original method with our new implementation.
    // This will ensure that if someone else's code on another thread is messing
    // with the class' method list too, we always have a valid method at all times.
    //
    // If the class does not implement the method itself then
    // class_replaceMethod returns NULL and superclasses's implementation will be used.
    //
    // We need a lock to be sure that originalIMP has the right value in the
    // originalImpProvider block above.
    OSSpinLockLock(&lock);
    originalIMP = class_replaceMethod(classToSwizzle, selector, newIMP, methodType);
    OSSpinLockUnlock(&lock);
}

static NSMutableDictionary *TL_swizzledClassesDictionary(){
    static NSMutableDictionary *swizzledClasses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        swizzledClasses = [NSMutableDictionary new];
    });
    return swizzledClasses;
}

static NSMutableSet *TL_swizzledClassesForKey(const void *key){
    NSMutableDictionary *classesDictionary = TL_swizzledClassesDictionary();
    NSValue *keyValue = [NSValue valueWithPointer:key];
    NSMutableSet *swizzledClasses = [classesDictionary objectForKey:keyValue];
    if (!swizzledClasses) {
        swizzledClasses = [NSMutableSet new];
        [classesDictionary setObject:swizzledClasses forKey:keyValue];
    }
    return swizzledClasses;
}

+(BOOL)swizzleInstanceMethod:(SEL)selector
                     inClass:(Class)classToSwizzle
               newImpFactory:(TL_RSSwizzleImpFactoryBlock)factoryBlock
                        mode:(TL_RSSwizzleMode)mode
                         key:(const void *)key
             skipMethodCheck:(BOOL)skipMethodCheck
{
    NSAssert(!(NULL == key && TL_RSSwizzleModeAlways != mode),
             @"Key may not be NULL if mode is not TL_RSSwizzleModeAlways.");

    @synchronized(TL_swizzledClassesDictionary()){
        if (key){
            NSSet *swizzledClasses = TL_swizzledClassesForKey(key);
            if (mode == TL_RSSwizzleModeOncePerClass) {
                if ([swizzledClasses containsObject:classToSwizzle]){
                    return NO;
                }
            }else if (mode == TL_RSSwizzleModeOncePerClassAndSuperclasses){
                for (Class currentClass = classToSwizzle;
                     nil != currentClass;
                     currentClass = class_getSuperclass(currentClass))
                {
                    if ([swizzledClasses containsObject:currentClass]) {
                        return NO;
                    }
                }
            }
        }
        
        TL_swizzle(classToSwizzle, selector, factoryBlock, skipMethodCheck);
        
        if (key){
            [TL_swizzledClassesForKey(key) addObject:classToSwizzle];
        }
    }
    
    return YES;
}

+(void)swizzleClassMethod:(SEL)selector
                  inClass:(Class)classToSwizzle
            newImpFactory:(TL_RSSwizzleImpFactoryBlock)factoryBlock
          skipMethodCheck:(BOOL)skipMethodCheck
{
    [self swizzleInstanceMethod:selector
                        inClass:object_getClass(classToSwizzle)
                  newImpFactory:factoryBlock
                           mode:TL_RSSwizzleModeAlways
                            key:NULL
                skipMethodCheck:skipMethodCheck];
}


@end
