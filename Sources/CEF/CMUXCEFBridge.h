#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

bool CMUXCEFPrepareApplication(void);
bool CMUXCEFIsRuntimeAvailable(void);
bool CMUXCEFIsInitialized(void);
bool CMUXCEFInitialize(int argc, char* _Nullable argv[_Nonnull]);
void CMUXCEFFlushBrowserState(void (^_Nullable completion)(void));
void CMUXCEFShutdown(void);
int CMUXCEFRemoteDebuggingPort(void);

#ifdef __cplusplus
}
#endif

@interface CMUXCEFBrowserView : NSView

@property(nonatomic, copy, nullable) void (^titleChangedHandler)(NSString* title);
@property(nonatomic, copy, nullable) void (^urlChangedHandler)(NSString* url);
@property(nonatomic, copy, nullable) void (^faviconURLChangedHandler)(NSString* faviconURL);
@property(nonatomic, copy, nullable) void (^navigationStateChangedHandler)(BOOL canGoBack, BOOL canGoForward, BOOL isLoading);
@property(nonatomic, copy, nullable) void (^consoleMessageHandler)(NSString* message, NSString* source, NSInteger line);
@property(nonatomic, copy, nullable) void (^newWindowRequestedHandler)(NSString* url);
@property(nonatomic, copy, nullable) void (^loadEventHandler)(
  NSString* event,
  NSString* url,
  NSInteger httpStatusCode,
  NSInteger errorCode,
  NSString* errorText);

- (instancetype)initWithFrame:(NSRect)frameRect
                   initialURL:(NSString*)initialURL NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(nonatomic, readonly, nullable) NSString* currentURLString;
@property(nonatomic, readonly, nullable) NSString* pageTitle;
@property(nonatomic, readonly) NSInteger browserIdentifier;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL isLoading;

- (void)loadURLString:(NSString*)urlString;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)executeJavaScript:(NSString*)javaScript;
- (void)toggleDevTools;
- (void)closeBrowser;

@end

NS_ASSUME_NONNULL_END
