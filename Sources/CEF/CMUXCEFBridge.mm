#import "CMUXCEFBridge.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "include/base/cef_logging.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"

static int g_remoteDebuggingPort = 9433;
static bool g_cefInitialized = false;
static bool g_cefShuttingDown = false;
static CefRefPtr<CefApp> g_cefApp;
static CFRunLoopTimerRef g_messagePumpTimer = nullptr;
static std::map<std::string, CefRefPtr<CefRequestContext>> g_persistentRequestContexts;
static NSString* const CMUXCEFBuiltInDefaultProfileIdentifier = @"52B43C05-4A1D-45D3-8FD5-9EF94952E445";
using CMUXCEFCompletionBlock = void (^)(void);

struct CMUXCEFProfileFlushState {
  explicit CMUXCEFProfileFlushState(CMUXCEFCompletionBlock completionBlock)
      : completion([completionBlock copy]) {}

  ~CMUXCEFProfileFlushState() {
    completion = nil;
  }

  std::atomic<int> pending{0};
  CMUXCEFCompletionBlock completion;
};

static NSString* CMUXNSStringFromCefString(const CefString& value) {
  std::string stringValue = value.ToString();
  return [NSString stringWithUTF8String:stringValue.c_str()] ?: @"";
}

static void CMUXCEFFinishProfileFlush(std::shared_ptr<CMUXCEFProfileFlushState> state) {
  if (!state || state->pending.fetch_sub(1) != 1) {
    return;
  }
  CMUXCEFCompletionBlock completion = [state->completion copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (completion) {
      completion();
    }
  });
}

class CMUXCEFCookieFlushCallback : public CefCompletionCallback {
 public:
  explicit CMUXCEFCookieFlushCallback(std::shared_ptr<CMUXCEFProfileFlushState> state)
      : state_(std::move(state)) {}

  void OnComplete() override {
    CMUXCEFFinishProfileFlush(state_);
  }

 private:
  std::shared_ptr<CMUXCEFProfileFlushState> state_;

  IMPLEMENT_REFCOUNTING(CMUXCEFCookieFlushCallback);
  DISALLOW_COPY_AND_ASSIGN(CMUXCEFCookieFlushCallback);
};

static bool CMUXCEFFlushCookieManager(CefRefPtr<CefCookieManager> manager,
                                      std::shared_ptr<CMUXCEFProfileFlushState> state) {
  if (!manager || !state) {
    return false;
  }
  state->pending.fetch_add(1);
  if (!manager->FlushStore(new CMUXCEFCookieFlushCallback(state))) {
    CMUXCEFFinishProfileFlush(state);
    return false;
  }
  return true;
}

static bool CMUXCEFIsPortAvailable(int port) {
  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) {
    return false;
  }
  int opt = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(static_cast<uint16_t>(port));

  int result = bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
  close(sock);
  return result == 0;
}

static int CMUXCEFFindAvailableRemoteDebuggingPort(void) {
  for (int port = 9433; port <= 9443; ++port) {
    if (CMUXCEFIsPortAvailable(port)) {
      return port;
    }
  }
  return 9433;
}

static NSString* CMUXCEFStorageNamespace(void) {
  NSString* bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.cmuxterm.app";
  if ([bundleIdentifier hasPrefix:@"com.cmuxterm.app.debug."]) {
    return @"com.cmuxterm.app.debug";
  }
  if ([bundleIdentifier hasPrefix:@"com.cmuxterm.app.staging."]) {
    return @"com.cmuxterm.app.staging";
  }
  return bundleIdentifier;
}

static NSString* CMUXCEFStorageDirectory(void) {
  NSArray<NSURL*>* appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask];
  NSString* appSupportPath = appSupportURLs.firstObject.path;
  if (appSupportPath.length == 0) {
    appSupportPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
  }
  NSString* path = [[appSupportPath stringByAppendingPathComponent:CMUXCEFStorageNamespace()]
    stringByAppendingPathComponent:@"cef"];
  [[NSFileManager defaultManager] createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return path;
}

static CefRefPtr<CefRequestContext> CMUXCEFRequestContextForProfile(NSString* profileIdentifier) {
  NSString* identifier = profileIdentifier.length > 0 ? profileIdentifier : @"default";
  if ([identifier isEqualToString:@"default"] || [identifier isEqualToString:CMUXCEFBuiltInDefaultProfileIdentifier]) {
    return CefRequestContext::GetGlobalContext();
  }

  std::string key([identifier UTF8String]);
  auto existing = g_persistentRequestContexts.find(key);
  if (existing != g_persistentRequestContexts.end()) {
    return existing->second;
  }

  NSString* profilePath = [CMUXCEFStorageDirectory() stringByAppendingPathComponent:identifier];
  [[NSFileManager defaultManager] createDirectoryAtPath:profilePath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

  CefRequestContextSettings contextSettings;
  contextSettings.persist_session_cookies = true;
  CefString(&contextSettings.cache_path) = [profilePath UTF8String];
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(contextSettings, nullptr);
  if (!context) {
    NSLog(@"[CEF] Failed to create persistent request context for profile %@; using global context.", identifier);
    return CefRequestContext::GetGlobalContext();
  }
  g_persistentRequestContexts[key] = context;
  return context;
}

static NSString* CMUXCEFFrameworkExecutablePath(void) {
  return [[[NSBundle mainBundle] privateFrameworksPath]
    stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
}

static NSString* CMUXCEFFrameworkBundlePath(void) {
  return [[[NSBundle mainBundle] privateFrameworksPath]
    stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
}

static NSString* CMUXCEFHelperExecutablePath(void) {
  return [[[NSBundle mainBundle] privateFrameworksPath]
    stringByAppendingPathComponent:@"cmux Helper.app/Contents/MacOS/cmux Helper"];
}

static void CMUXCEFInvalidateMessagePumpTimer(void) {
  if (!g_messagePumpTimer) {
    return;
  }
  CFRunLoopTimerInvalidate(g_messagePumpTimer);
  CFRelease(g_messagePumpTimer);
  g_messagePumpTimer = nullptr;
}

static void CMUXCEFRunMessagePumpWork(void) {
  if (!g_cefInitialized || g_cefShuttingDown) {
    return;
  }
  CefDoMessageLoopWork();
}

static void CMUXCEFScheduleMessagePumpWork(int64_t delayMs) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!g_cefInitialized || g_cefShuttingDown) {
      return;
    }
    CMUXCEFInvalidateMessagePumpTimer();
    if (delayMs <= 0) {
      CMUXCEFRunMessagePumpWork();
      return;
    }

    CFAbsoluteTime fireDate = CFAbsoluteTimeGetCurrent() + (static_cast<CFTimeInterval>(delayMs) / 1000.0);
    g_messagePumpTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fireDate, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
      if (g_messagePumpTimer == timer) {
        CFRelease(g_messagePumpTimer);
        g_messagePumpTimer = nullptr;
      }
      CMUXCEFRunMessagePumpWork();
    });
    CFRunLoopAddTimer(CFRunLoopGetMain(), g_messagePumpTimer, kCFRunLoopCommonModes);
  });
}

@interface CMUXCEFApplication : NSApplication<CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation CMUXCEFApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

class CMUXCEFApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CMUXCEFApp() = default;

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("use-mock-keychain");
    command_line->AppendSwitch("enable-fullscreen");
    command_line->AppendSwitch("allow-insecure-localhost");
    command_line->AppendSwitchWithValue("remote-allow-origins", "*");
  }

  void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {
    command_line->AppendSwitch("disable-background-mode");
    command_line->AppendSwitch("disable-backgrounding-occluded-windows");
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    CMUXCEFScheduleMessagePumpWork(delay_ms);
  }

 private:
  IMPLEMENT_REFCOUNTING(CMUXCEFApp);
  DISALLOW_COPY_AND_ASSIGN(CMUXCEFApp);
};

@class CMUXCEFBrowserView;

class CMUXCEFBrowserClient : public CefClient,
                             public CefDisplayHandler,
                             public CefLoadHandler,
                             public CefLifeSpanHandler {
 public:
  explicit CMUXCEFBrowserClient(CMUXCEFBrowserView* owner) : owner_(owner) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) override;
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override;
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void MarkClosingFromCMUX();

 private:
  __weak CMUXCEFBrowserView* owner_;
  bool closingFromCMUX_ = false;

  IMPLEMENT_REFCOUNTING(CMUXCEFBrowserClient);
  DISALLOW_COPY_AND_ASSIGN(CMUXCEFBrowserClient);
};

@interface CMUXCEFBrowserView () {
 @private
  NSString* initialURL_;
  NSString* profileIdentifier_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CMUXCEFBrowserClient> client_;
  NSView* cefView_;
  NSString* currentURLString_;
  NSString* pageTitle_;
  BOOL canGoBack_;
  BOOL canGoForward_;
  BOOL isLoading_;
  BOOL didCreateBrowser_;
}
- (void)cmuxCEFSetTitle:(NSString*)title;
- (void)cmuxCEFSetURL:(NSString*)url;
- (void)cmuxCEFSetFaviconURL:(NSString*)url;
- (void)cmuxCEFSetLoading:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)cmuxCEFHandleLoadEvent:(NSString*)event
                           url:(NSString*)url
                httpStatusCode:(NSInteger)httpStatusCode
                      errorCode:(NSInteger)errorCode
                      errorText:(NSString*)errorText;
- (void)cmuxCEFHandleConsoleMessage:(NSString*)message source:(NSString*)source line:(NSInteger)line;
@end

@implementation CMUXCEFBrowserView

- (instancetype)initWithFrame:(NSRect)frameRect
                   initialURL:(NSString*)initialURL
            profileIdentifier:(NSString*)profileIdentifier {
  self = [super initWithFrame:frameRect];
  if (self) {
    initialURL_ = [initialURL copy];
    profileIdentifier_ = [profileIdentifier copy];
    currentURLString_ = [initialURL copy];
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.086 alpha:1].CGColor;
    self.layer.masksToBounds = YES;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (NSView*)hitTest:(NSPoint)point {
  if (!NSPointInRect(point, self.bounds)) {
    return nil;
  }
  if (cefView_ && !cefView_.hidden && cefView_.alphaValue > 0.0) {
    NSPoint cefPoint = [self convertPoint:point toView:cefView_];
    if (NSPointInRect(cefPoint, cefView_.bounds)) {
      NSView* hitView = [cefView_ hitTest:cefPoint];
      return hitView ?: cefView_;
    }
  }
  return [super hitTest:point];
}

- (BOOL)becomeFirstResponder {
  if (cefView_ && self.window) {
    [self.window makeFirstResponder:cefView_];
  }
  return [super becomeFirstResponder];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !didCreateBrowser_) {
    [self createBrowserIfNeeded];
  }
}

- (void)layout {
  [super layout];
  if (!cefView_) {
    return;
  }
  NSRect targetFrame = self.bounds;
  if (!NSEqualRects(cefView_.frame, targetFrame)) {
    cefView_.frame = targetFrame;
  }
  if (!NSEqualPoints(cefView_.bounds.origin, NSZeroPoint)) {
    [cefView_ setBoundsOrigin:NSZeroPoint];
  }
}

- (NSString*)currentURLString {
  return currentURLString_;
}

- (NSString*)pageTitle {
  return pageTitle_;
}

- (NSInteger)browserIdentifier {
  return browser_ ? browser_->GetIdentifier() : -1;
}

- (BOOL)canGoBack {
  return canGoBack_;
}

- (BOOL)canGoForward {
  return canGoForward_;
}

- (BOOL)isLoading {
  return isLoading_;
}

- (void)createBrowserIfNeeded {
  if (didCreateBrowser_ || !g_cefInitialized) {
    return;
  }
  didCreateBrowser_ = YES;

  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefRect rect(0, 0, static_cast<int>(MAX(1, self.bounds.size.width)), static_cast<int>(MAX(1, self.bounds.size.height)));
  windowInfo.SetAsChild((__bridge void*)self, rect);

  CefBrowserSettings browserSettings;
  browserSettings.background_color = CefColorSetARGB(255, 22, 22, 22);
  CefRefPtr<CefRequestContext> requestContext = CMUXCEFRequestContextForProfile(profileIdentifier_);

  client_ = new CMUXCEFBrowserClient(self);
  browser_ = CefBrowserHost::CreateBrowserSync(
    windowInfo,
    client_,
    CefString("about:blank"),
    browserSettings,
    nullptr,
    requestContext);
  if (!browser_) {
    return;
  }

  CefWindowHandle handle = browser_->GetHost()->GetWindowHandle();
  cefView_ = (__bridge NSView*)handle;
  cefView_.autoresizingMask = NSViewNotSizable;
  cefView_.frame = self.bounds;
  [self setNeedsLayout:YES];

  if (initialURL_.length > 0) {
    [self loadURLString:initialURL_];
  }
}

- (void)loadURLString:(NSString*)urlString {
  currentURLString_ = [urlString copy];
  if (self.urlChangedHandler) {
    self.urlChangedHandler(currentURLString_ ?: @"");
  }
  if (browser_ && urlString.length > 0) {
    browser_->GetMainFrame()->LoadURL(CefString([urlString UTF8String]));
  }
}

- (void)goBack {
  if (browser_ && browser_->CanGoBack()) {
    browser_->GoBack();
  }
}

- (void)goForward {
  if (browser_ && browser_->CanGoForward()) {
    browser_->GoForward();
  }
}

- (void)reload {
  if (browser_) {
    browser_->Reload();
  }
}

- (void)stopLoading {
  if (browser_) {
    browser_->StopLoad();
  }
}

- (void)executeJavaScript:(NSString*)javaScript {
  if (!browser_ || javaScript.length == 0) {
    return;
  }
  CefRefPtr<CefFrame> frame = browser_->GetMainFrame();
  if (frame) {
    frame->ExecuteJavaScript(CefString([javaScript UTF8String]), frame->GetURL(), 0);
  }
}

- (void)toggleDevTools {
  if (browser_) {
    NSLog(@"[CEF] Remote debugging is available at http://127.0.0.1:%d", g_remoteDebuggingPort);
  }
}

- (void)closeBrowser {
  if (browser_) {
    if (client_) {
      client_->MarkClosingFromCMUX();
    }
    browser_->GetHost()->CloseBrowser(true);
    browser_ = nullptr;
  }
  if (cefView_) {
    [cefView_ removeFromSuperview];
    cefView_ = nil;
  }
}

- (void)dealloc {
  [self closeBrowser];
}

- (void)cmuxCEFSetTitle:(NSString*)title {
  pageTitle_ = [title copy];
  if (self.titleChangedHandler) {
    self.titleChangedHandler(pageTitle_ ?: @"");
  }
}

- (void)cmuxCEFSetURL:(NSString*)url {
  currentURLString_ = [url copy];
  if (self.urlChangedHandler) {
    self.urlChangedHandler(currentURLString_ ?: @"");
  }
}

- (void)cmuxCEFSetFaviconURL:(NSString*)url {
  if (self.faviconURLChangedHandler) {
    self.faviconURLChangedHandler(url ?: @"");
  }
}

- (void)cmuxCEFSetLoading:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  isLoading_ = isLoading;
  canGoBack_ = canGoBack;
  canGoForward_ = canGoForward;
  if (self.navigationStateChangedHandler) {
    self.navigationStateChangedHandler(canGoBack_, canGoForward_, isLoading_);
  }
}

- (void)cmuxCEFHandleLoadEvent:(NSString*)event
                           url:(NSString*)url
                httpStatusCode:(NSInteger)httpStatusCode
                      errorCode:(NSInteger)errorCode
                      errorText:(NSString*)errorText {
  if (self.loadEventHandler) {
    self.loadEventHandler(event ?: @"", url ?: @"", httpStatusCode, errorCode, errorText ?: @"");
  }
}

- (void)cmuxCEFHandleConsoleMessage:(NSString*)message source:(NSString*)source line:(NSInteger)line {
  if (self.consoleMessageHandler) {
    self.consoleMessageHandler(message ?: @"", source ?: @"", line);
  }
}

@end

void CMUXCEFBrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  CMUXCEFBrowserView* owner = owner_;
  NSString* titleString = CMUXNSStringFromCefString(title);
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFSetTitle:titleString];
  });
}

void CMUXCEFBrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) {
  if (!frame || !frame->IsMain()) {
    return;
  }
  CMUXCEFBrowserView* owner = owner_;
  NSString* urlString = CMUXNSStringFromCefString(url);
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFSetURL:urlString];
  });
}

void CMUXCEFBrowserClient::OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) {
  if (icon_urls.empty()) {
    return;
  }
  CMUXCEFBrowserView* owner = owner_;
  NSString* faviconURL = CMUXNSStringFromCefString(icon_urls.front());
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFSetFaviconURL:faviconURL];
  });
}

void CMUXCEFBrowserClient::OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) {
  if (!frame || !frame->IsMain()) {
    return;
  }
  CMUXCEFBrowserView* owner = owner_;
  NSString* urlString = CMUXNSStringFromCefString(frame->GetURL());
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFHandleLoadEvent:@"loadStart" url:urlString httpStatusCode:0 errorCode:0 errorText:@""];
  });
}

void CMUXCEFBrowserClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) {
  if (!frame || !frame->IsMain()) {
    return;
  }
  CMUXCEFBrowserView* owner = owner_;
  NSString* urlString = CMUXNSStringFromCefString(frame->GetURL());
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFHandleLoadEvent:@"loadEnd" url:urlString httpStatusCode:httpStatusCode errorCode:0 errorText:@""];
  });
}

void CMUXCEFBrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       ErrorCode errorCode,
                                       const CefString& errorText,
                                       const CefString& failedUrl) {
  if (!frame || !frame->IsMain()) {
    return;
  }
  CMUXCEFBrowserView* owner = owner_;
  NSString* urlString = CMUXNSStringFromCefString(failedUrl);
  NSString* errorTextString = CMUXNSStringFromCefString(errorText);
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFHandleLoadEvent:@"loadError"
                              url:urlString
                   httpStatusCode:0
                         errorCode:static_cast<NSInteger>(errorCode)
                         errorText:errorTextString];
  });
}

void CMUXCEFBrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) {
  CMUXCEFBrowserView* owner = owner_;
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFSetLoading:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  });
}

bool CMUXCEFBrowserClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                            cef_log_severity_t level,
                                            const CefString& message,
                                            const CefString& source,
                                            int line) {
  CMUXCEFBrowserView* owner = owner_;
  NSString* messageString = CMUXNSStringFromCefString(message);
  NSString* sourceString = CMUXNSStringFromCefString(source);
  dispatch_async(dispatch_get_main_queue(), ^{
    [owner cmuxCEFHandleConsoleMessage:messageString source:sourceString line:line];
  });
  return false;
}

bool CMUXCEFBrowserClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         int popup_id,
                                         const CefString& target_url,
                                         const CefString& target_frame_name,
                                         CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                                         bool user_gesture,
                                         const CefPopupFeatures& popupFeatures,
                                         CefWindowInfo& windowInfo,
                                         CefRefPtr<CefClient>& client,
                                         CefBrowserSettings& settings,
                                         CefRefPtr<CefDictionaryValue>& extra_info,
                                         bool* no_javascript_access) {
  std::string url = target_url.ToString();
  CMUXCEFBrowserView* owner = owner_;
  if (!url.empty() && owner.newWindowRequestedHandler) {
    NSString* requestedURL = CMUXNSStringFromCefString(target_url);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (owner.newWindowRequestedHandler) {
        owner.newWindowRequestedHandler(requestedURL);
      }
    });
    return true;
  }
  if (browser && !url.empty()) {
    browser->GetMainFrame()->LoadURL(target_url);
  }
  return true;
}

bool CMUXCEFBrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
  return closingFromCMUX_;
}

void CMUXCEFBrowserClient::MarkClosingFromCMUX() {
  closingFromCMUX_ = true;
}

bool CMUXCEFPrepareApplication(void) {
  [CMUXCEFApplication sharedApplication];
  return [NSApp isKindOfClass:[CMUXCEFApplication class]];
}

bool CMUXCEFIsRuntimeAvailable(void) {
  return [[NSFileManager defaultManager] fileExistsAtPath:CMUXCEFFrameworkExecutablePath()]
    && [[NSFileManager defaultManager] fileExistsAtPath:CMUXCEFHelperExecutablePath()];
}

bool CMUXCEFIsInitialized(void) {
  return g_cefInitialized;
}

bool CMUXCEFInitialize(int argc, char* _Nullable argv[]) {
  if (g_cefInitialized) {
    return true;
  }
  if (![NSApp isKindOfClass:[CMUXCEFApplication class]]) {
    return false;
  }
  if (!CMUXCEFIsRuntimeAvailable()) {
    NSLog(@"[CEF] Runtime not available. Missing framework or helper app.");
    return false;
  }

  CefMainArgs mainArgs(argc, argv);
  g_cefApp = new CMUXCEFApp();

  CefSettings settings;
  settings.no_sandbox = true;
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = true;
  settings.windowless_rendering_enabled = false;
  g_remoteDebuggingPort = CMUXCEFFindAvailableRemoteDebuggingPort();
  settings.remote_debugging_port = g_remoteDebuggingPort;

  NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
  if (bundlePath) {
    CefString(&settings.main_bundle_path) = [bundlePath UTF8String];
  }
  CefString(&settings.framework_dir_path) = [CMUXCEFFrameworkBundlePath() UTF8String];
  CefString(&settings.browser_subprocess_path) = [CMUXCEFHelperExecutablePath() UTF8String];

  NSString* cachePath = CMUXCEFStorageDirectory();
  CefString(&settings.cache_path) = [cachePath UTF8String];
  CefString(&settings.root_cache_path) = [cachePath UTF8String];
  settings.persist_session_cookies = true;
  CefString(&settings.log_file) = [[cachePath stringByAppendingPathComponent:@"debug.log"] UTF8String];
  settings.log_severity = LOGSEVERITY_ERROR;
  CefString(&settings.accept_language_list) = "en-US,en";

  if (!CefInitialize(mainArgs, settings, g_cefApp.get(), nullptr)) {
    NSLog(@"[CEF] CefInitialize failed.");
    return false;
  }
  g_cefInitialized = true;
  g_cefShuttingDown = false;
  CMUXCEFScheduleMessagePumpWork(0);
  NSLog(@"[CEF] Initialized with remote debugging on 127.0.0.1:%d", g_remoteDebuggingPort);
  return true;
}

void CMUXCEFFlushBrowserState(CMUXCEFCompletionBlock completion) {
  auto state = std::make_shared<CMUXCEFProfileFlushState>(completion);
  if (g_cefInitialized) {
    CefRefPtr<CefRequestContext> globalContext = CefRequestContext::GetGlobalContext();
    if (globalContext) {
      CMUXCEFFlushCookieManager(globalContext->GetCookieManager(nullptr), state);
    }
    for (const auto& entry : g_persistentRequestContexts) {
      if (entry.second) {
        CMUXCEFFlushCookieManager(entry.second->GetCookieManager(nullptr), state);
      }
    }
  }
  if (state->pending.load() == 0 && completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion();
    });
  }
}

void CMUXCEFShutdown(void) {
  if (!g_cefInitialized) {
    return;
  }
  g_cefShuttingDown = true;
  CMUXCEFInvalidateMessagePumpTimer();
  CefShutdown();
  g_persistentRequestContexts.clear();
  g_cefApp = nullptr;
  g_cefInitialized = false;
  g_cefShuttingDown = false;
}

int CMUXCEFRemoteDebuggingPort(void) {
  return g_remoteDebuggingPort;
}
