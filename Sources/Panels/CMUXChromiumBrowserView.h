#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CMUXChromiumDevToolsPresentation) {
    CMUXChromiumDevToolsPresentationDocked = 0,
    CMUXChromiumDevToolsPresentationWindow = 1,
};

@interface CMUXChromiumRuntime : NSObject

+ (instancetype)sharedRuntime NS_SWIFT_NAME(shared());

@property (nonatomic, readonly, getter=isRuntimeAvailable) BOOL runtimeAvailable;
@property (nonatomic, readonly, getter=isBrowserHostAvailable) BOOL browserHostAvailable;
@property (nonatomic, copy, readonly, nullable) NSString *frameworkExecutablePath;
@property (nonatomic, copy, readonly, nullable) NSString *lastErrorMessage;

- (void)reloadAvailability;

@end

@interface CMUXChromiumBrowserView : NSView

- (instancetype)initWithProfileIdentifier:(NSString *)profileIdentifier
                     extensionDirectories:(NSArray<NSString *> *)extensionDirectories NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, copy, readonly) NSString *profileIdentifier;
@property (nonatomic, copy, readonly) NSArray<NSString *> *extensionDirectories;
@property (nonatomic, copy, nullable) void (^navigationStateChanged)(CMUXChromiumBrowserView *browserView);
@property (nonatomic, copy, nullable) void (^titleChanged)(CMUXChromiumBrowserView *browserView);
@property (nonatomic, copy, nullable) void (^loadFailed)(CMUXChromiumBrowserView *browserView, NSString *message);

@property (nonatomic, copy, readonly, nullable) NSString *lastCommittedURLString;
@property (nonatomic, copy, readonly, nullable) NSString *pageTitle;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly, getter=isDeveloperToolsVisible) BOOL developerToolsVisible;

- (void)loadURLString:(NSString *)urlString;
- (void)reloadPage;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;
- (void)setPageZoomFactor:(double)pageZoomFactor;
- (BOOL)showDevToolsWithPresentation:(CMUXChromiumDevToolsPresentation)presentation;
- (BOOL)closeDevTools;
- (BOOL)loadExtensionAtPath:(NSString *)path errorMessage:(NSString * _Nullable * _Nullable)errorMessage;
- (void)evaluateJavaScript:(NSString *)script completion:(void (^ _Nullable)(id _Nullable result, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

