// CMUXCEFBridge.mm — ObjC++ implementation of the cmux ⇄ CEF bridge.
//
// Layering rules:
//   * Only this file (and the helper main.mm files) include CEF C++ headers.
//   * Swift never sees a CefRefPtr or CefBaseRefCounted; only Foundation /
//     AppKit types declared in CMUXCEFBridge.h.
//   * Every callback that crosses back into Swift is dispatched on the main
//     thread.
//
// The bridge currently implements:
//   * engine lifecycle (CefInitialize / CefShutdown)
//   * subprocess routing (CefExecuteProcess via CMUXCEFEngineBridge
//     +executeSubprocessIfNeededWithArgc:argv:)
//   * CefApp subclass that forwards cmux configuration into the Chromium
//     command line on every browser-process spin-up
//   * profile registry that wraps CefRequestContext with cmux-friendly
//     names ("default", "work", "isolated-<uuid>")
//
// Pending (tracked in DESIGN.md §9 Step 2..6):
//   * actual browser creation via CefBrowserView + CefWindow (top-level
//     borderless NSWindow per pane)
//   * CefClient subclass plumbing the load / title / navigation callbacks
//     back into CMUXCEFBrowserBridgeDelegate
//   * DevTools wiring
// These are tagged `CMUX_TODO`.

#import "include/CMUXCEFBridge.h"

#include <atomic>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <os/log.h>

// CEF includes. Keep these confined to .mm files.
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "include/wrapper/cef_helpers.h"

// MARK: - Constants

static NSString * const kCMUXCEFErrorDomain = @"CMUXCEF";
static NSString * const kCMUXCEFFrameworksDirEnv = @"CMUX_CEF_FRAMEWORKS_DIR";

static os_log_t cmuxCEFLog(void) {
    static os_log_t log = os_log_create("co.manaflow.cmux", "CMUXCEF");
    return log;
}

static std::atomic_bool gCMUXCEFMessagePumpRunning{false};

static void CMUXCEFRunMessagePumpWorkIfIdle(void) {
    bool expected = false;
    if (!gCMUXCEFMessagePumpRunning.compare_exchange_strong(expected, true)) {
        return;
    }
    CefDoMessageLoopWork();
    gCMUXCEFMessagePumpRunning.store(false);
}

static void CMUXCEFPostMessagePumpWork(int64_t delay_ms) {
    dispatch_time_t when = (delay_ms <= 0)
        ? DISPATCH_TIME_NOW
        : dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC);
    dispatch_after(when, dispatch_get_main_queue(), ^{
        CMUXCEFRunMessagePumpWorkIfIdle();
    });
}

typedef NS_ENUM(NSInteger, CMUXCEFInitError) {
    CMUXCEFInitErrorAlreadyInitialized   = 1,
    CMUXCEFInitErrorMissingRootCachePath = 2,
    CMUXCEFInitErrorCefInitializeFailed  = 3,
};

static NSString *CMUXCEFFrameworkBinaryPath(NSString *frameworksDir) {
    return [frameworksDir stringByAppendingPathComponent:
            @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
}

static NSString *CMUXCEFResolveFrameworkBinaryPathFromArgv0(const char *argv0) {
    NSString *envPath = [NSProcessInfo processInfo].environment[kCMUXCEFFrameworksDirEnv];
    if (envPath.length > 0) {
        return CMUXCEFFrameworkBinaryPath(envPath);
    }

    if (argv0) {
        NSString *executablePath = [[NSString stringWithUTF8String:argv0] stringByStandardizingPath];
        if (executablePath.length > 0) {
            NSURL *url = [NSURL fileURLWithPath:executablePath];

            // Packaged cmux browser process:
            //   cmux.app/Contents/MacOS/cmux
            NSURL *contentsURL = [[url URLByDeletingLastPathComponent]
                                      URLByDeletingLastPathComponent];
            NSString *mainAppCandidate =
                CMUXCEFFrameworkBinaryPath([contentsURL.path stringByAppendingPathComponent:@"Frameworks"]);
            if ([[NSFileManager defaultManager] fileExistsAtPath:mainAppCandidate]) {
                return mainAppCandidate;
            }

            // Packaged cmux helpers:
            //   cmux.app/Contents/Frameworks/cmux Helper.app/Contents/MacOS/...
            NSURL *helperFrameworksURL = [[[[url URLByDeletingLastPathComponent]
                                             URLByDeletingLastPathComponent]
                                             URLByDeletingLastPathComponent]
                                             URLByDeletingLastPathComponent];
            NSString *helperCandidate = CMUXCEFFrameworkBinaryPath(helperFrameworksURL.path);
            if ([[NSFileManager defaultManager] fileExistsAtPath:helperCandidate]) {
                return helperCandidate;
            }
        }
    }

    // SwiftPM demo/dev fallback. CMUXCEFDemoApp is normally launched from
    // the package root and keeps CEFArtifacts -> Frameworks there.
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    for (NSString *dirName in @[@"CEFArtifacts", @"Frameworks"]) {
        NSString *candidate = CMUXCEFFrameworkBinaryPath([cwd stringByAppendingPathComponent:dirName]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }

    return nil;
}

static BOOL CMUXCEFEnsureFrameworkLoaded(NSString *frameworkBinaryPath, NSError **error) {
    static std::mutex mutex;
    static BOOL loaded = NO;
    static NSString *loadedPath = nil;

    std::lock_guard<std::mutex> lock(mutex);
    if (loaded) {
        return YES;
    }

    if (frameworkBinaryPath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:frameworkBinaryPath]) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain
                                         code:CMUXCEFInitErrorCefInitializeFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString
                                        stringWithFormat:@"CEF framework binary not found at %@",
                                         frameworkBinaryPath ?: @"<nil>"]}];
        }
        return NO;
    }

    if (!cef_load_library([frameworkBinaryPath UTF8String])) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain
                                         code:CMUXCEFInitErrorCefInitializeFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString
                                        stringWithFormat:@"cef_load_library failed at %@",
                                         frameworkBinaryPath]}];
        }
        return NO;
    }

    loadedPath = [frameworkBinaryPath copy];
    loaded = YES;
    os_log(cmuxCEFLog(), "CEF framework loaded from %{public}@", loadedPath);
    return YES;
}

// MARK: - CefApp subclass (browser process)

namespace {

class CMUXCEFApp final : public CefApp, public CefBrowserProcessHandler {
public:
    explicit CMUXCEFApp(NSString * _Nullable loadExtensionsArg,
                        NSString * _Nullable userAgentProduct)
        : load_extensions_(loadExtensionsArg ? [loadExtensionsArg UTF8String] : ""),
          user_agent_product_(userAgentProduct ? [userAgentProduct UTF8String] : "") {}

    // CefApp:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        // Forward cmux-curated extension list. Process-global; per-profile
        // state isolation handled by per-CefRequestContext cache_path.
        if (!load_extensions_.empty() && !command_line->HasSwitch("load-extension")) {
            command_line->AppendSwitchWithValue("load-extension", load_extensions_);
        }
        // chrome:// URLs need this to expose extension pages, devtools-on-self, etc.
        if (!command_line->HasSwitch("extensions-on-chrome-urls")) {
            command_line->AppendSwitch("extensions-on-chrome-urls");
        }
        // Dev builds: the ad-hoc-signed CEF framework and helpers cannot
        // satisfy macOS GPU sandbox prerequisites. Production cmux builds
        // re-sign with Developer ID and these switches go away.
        if (!command_line->HasSwitch("no-sandbox")) {
            command_line->AppendSwitch("no-sandbox");
        }
        if (!command_line->HasSwitch("disable-gpu-sandbox")) {
            command_line->AppendSwitch("disable-gpu-sandbox");
        }
        // Without a fully-integrated app bundle the GPU helper can't find
        // ANGLE's libGLESv2.dylib. CPU compositing is fine for dev.
        if (!command_line->HasSwitch("disable-gpu")) {
            command_line->AppendSwitch("disable-gpu");
        }
        if (!command_line->HasSwitch("disable-gpu-compositing")) {
            command_line->AppendSwitch("disable-gpu-compositing");
        }
    }

    // CefBrowserProcessHandler:
    void OnContextInitialized() override {
        // Nothing per-context here — cmux is the one creating browsers.
    }

    // Called by CEF from its UI thread whenever it wants the host to
    // drain `CefDoMessageLoopWork()` after `delay_ms`. We hop to the
    // main run loop and schedule one pump there. With
    // `external_message_pump = true` the entire CEF UI message queue
    // (including helper-process Mojo bootstrap invitations) is gated on
    // this — no pump = wedged helpers = the 15s timeout we kept seeing.
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        // Never call CefDoMessageLoopWork inline from this callback.
        // Chromium may schedule more pump work while AppKit is still in
        // synchronous focus / mouse handling. Re-entering the pump in
        // that stack can deadlock inside CEF's internal mutexes.
        CMUXCEFPostMessagePumpWork(delay_ms);
    }

private:
    std::string load_extensions_;
    std::string user_agent_product_;

    IMPLEMENT_REFCOUNTING(CMUXCEFApp);
    DISALLOW_COPY_AND_ASSIGN(CMUXCEFApp);
};

}  // namespace

// MARK: - Engine bridge

@implementation CMUXCEFEngineConfigBridge
@end

@implementation CMUXCEFEngineBridge {
    std::atomic<bool> _initialized;
    CefRefPtr<CMUXCEFApp> _app;
}

+ (instancetype)shared {
    static CMUXCEFEngineBridge *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[CMUXCEFEngineBridge alloc] init]; });
    return instance;
}

+ (int)executeSubprocessIfNeededWithArgc:(int)argc argv:(char **)argv {
    // The browser process must not call CefExecuteProcess here. With the
    // SwiftPM demo and cmux app bundle shape, doing so can wedge the later
    // CefInitialize call before browser creation. Helpers still need this
    // path and must bind libcef's stub table before entering CEF's loop.
    BOOL isSubprocess = NO;
    for (int i = 1; i < argc; ++i) {
        if (argv[i] && strncmp(argv[i], "--type=", 7) == 0) {
            isSubprocess = YES;
            break;
        }
    }
    if (!isSubprocess) {
        return -1;
    }
    @autoreleasepool {
        NSString *frameworkBinaryPath =
            CMUXCEFResolveFrameworkBinaryPathFromArgv0(argc > 0 ? argv[0] : nullptr);
        NSError *loadError = nil;
        if (!CMUXCEFEnsureFrameworkLoaded(frameworkBinaryPath, &loadError)) {
            fprintf(stderr, "CMUXCEF subprocess failed to load CEF framework: %s\n",
                    loadError.localizedDescription.UTF8String);
            return 1;
        }
        CefMainArgs main_args(argc, argv);
        CefRefPtr<CMUXCEFApp> app(new CMUXCEFApp(nil, nil));
        int code = CefExecuteProcess(main_args, app, nullptr);
        if (code >= 0) {
            return code;
        }
        return -1;
    }
}

- (BOOL)isInitialized { return _initialized.load(); }

- (BOOL)initializeWithConfig:(CMUXCEFEngineConfigBridge *)config
                       error:(NSError **)error {
    if (_initialized.load()) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain
                                         code:CMUXCEFInitErrorAlreadyInitialized
                                     userInfo:@{NSLocalizedDescriptionKey: @"CEF already initialized"}];
        }
        return NO;
    }
    if (config.rootCachePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain
                                         code:CMUXCEFInitErrorMissingRootCachePath
                                     userInfo:@{NSLocalizedDescriptionKey: @"rootCachePath is required"}];
        }
        return NO;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:config.rootCachePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // CEF on macOS is shipped as a stub library: the libcef_dll_wrapper
    // static archive contains a per-symbol stub that branches through a
    // function-pointer table. That table is empty until cef_load_library()
    // dlopen's the real framework and resolves each export. Without this
    // call, every CefString operation jumps to NULL.
    if (config.frameworkDirectoryPath.length > 0) {
        setenv([kCMUXCEFFrameworksDirEnv UTF8String],
               [config.frameworkDirectoryPath fileSystemRepresentation],
               1);
        NSString *fwBinary = CMUXCEFFrameworkBinaryPath(config.frameworkDirectoryPath);
        if (!CMUXCEFEnsureFrameworkLoaded(fwBinary, error)) {
            return NO;
        }
    }

    CefMainArgs main_args(0, nullptr);
    CefSettings settings;
    // Dev/ad-hoc-signed CEF helpers do not carry Chromium's sandbox
    // signing profile. This must be set at CefSettings level; appending a
    // late --no-sandbox switch is not enough for early services created
    // during CefInitialize (notably network.mojom.NetworkService).
    settings.no_sandbox = true;
    // cmux is a SwiftUI / AppKit app — its main thread runs
    // NSApplication's run loop, NOT `CefRunMessageLoop()`. Without an
    // external pump, CEF's UI thread message queue (which carries every
    // browser → helper Mojo invitation) is never drained, helpers wait
    // 15s for a bootstrap message that never arrives, and they suicide
    // via `content/child/child_thread_impl.cc:902`. With
    // `external_message_pump = true` CEF stays inert until we call
    // `CefDoMessageLoopWork()` from the main run loop.
    settings.external_message_pump = true;
    CefString(&settings.root_cache_path).FromString([config.rootCachePath UTF8String]);
    if (config.userAgentProduct.length > 0) {
        CefString(&settings.user_agent_product)
            .FromString([config.userAgentProduct UTF8String]);
    }
    if (config.logSeverity > 0 && config.logSeverity <= 5) {
        settings.log_severity = static_cast<cef_log_severity_t>(config.logSeverity);
    }
    if (config.frameworkDirectoryPath.length > 0) {
        NSString *fwDir = config.frameworkDirectoryPath;
        NSString *fwBundle = [fwDir stringByAppendingPathComponent:
                              @"Chromium Embedded Framework.framework"];
        NSString *resources = [fwBundle stringByAppendingPathComponent:
                               @"Versions/A/Resources"];
        CefString(&settings.framework_dir_path).FromString([fwBundle UTF8String]);
        CefString(&settings.resources_dir_path).FromString([resources UTF8String]);
        CefString(&settings.locales_dir_path).FromString(
            [[resources stringByAppendingPathComponent:@"locales"] UTF8String]);
    }
    if (config.browserSubprocessPath.length > 0) {
        CefString(&settings.browser_subprocess_path)
            .FromString([config.browserSubprocessPath UTF8String]);
    }

    _app = new CMUXCEFApp(config.loadExtensionsArg, config.userAgentProduct);
    if (!CefInitialize(main_args, settings, _app, nullptr)) {
        _app = nullptr;
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain
                                         code:CMUXCEFInitErrorCefInitializeFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"CefInitialize failed"}];
        }
        return NO;
    }

    _initialized.store(true);
    // Anchor the profile registry under the engine's root_cache_path so
    // per-profile cache dirs satisfy CEF's "child of root_cache_path" check.
    [CMUXCEFProfileRegistryBridge shared].profilesRoot =
        [config.rootCachePath stringByAppendingPathComponent:@"profiles"];
    // Kick the external pump immediately so CEF gets one tick and a chance
    // to install its `OnScheduleMessagePumpWork` callback for subsequent
    // ticks.
    CMUXCEFPostMessagePumpWork(0);
    // Belt-and-braces fallback: also drive CefDoMessageLoopWork from a
    // 30Hz NSTimer. `OnScheduleMessagePumpWork` is the optimal path, but
    // SwiftUI re-renders or modal panels can starve the main queue and
    // leave Mojo bootstrap messages undelivered — which is what wedged
    // the second-and-later CEF browsers in cmux. The fallback timer
    // guarantees forward progress even when CEF's own callback is late.
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                     target:self
                                   selector:@selector(_cmuxCefPumpTick:)
                                   userInfo:nil
                                    repeats:YES];
    os_log(cmuxCEFLog(), "CMUXCEFEngine initialized; root_cache_path=%{public}@",
           config.rootCachePath);
    return YES;
}

- (void)shutdown {
    if (!_initialized.exchange(false)) return;
    os_log(cmuxCEFLog(), "CMUXCEFEngine shutting down");
    CefShutdown();
    _app = nullptr;
}

- (void)runMessageLoop {
    if (!_initialized.load()) return;
    CefRunMessageLoop();
}

- (void)quitMessageLoop {
    if (!_initialized.load()) return;
    CefQuitMessageLoop();
}

- (void)_cmuxCefPumpTick:(NSTimer *)timer {
    if (!_initialized.load()) {
        [timer invalidate];
        return;
    }
    CMUXCEFRunMessagePumpWorkIfIdle();
}

@end

// MARK: - Profile registry

@interface CMUXCEFProfileBridge ()
- (CefRefPtr<CefRequestContext>)underlyingContext;
@end

@implementation CMUXCEFProfileBridge {
    CefRefPtr<CefRequestContext> _context;
}

- (instancetype)initWithName:(NSString *)name
                   cachePath:(NSString *)cachePath
                     context:(CefRefPtr<CefRequestContext>)context {
    if ((self = [super init])) {
        _name = [name copy];
        _cachePath = [cachePath copy];
        _context = context;
    }
    return self;
}

- (CefRefPtr<CefRequestContext>)underlyingContext { return _context; }

@end


@implementation CMUXCEFProfileRegistryBridge {
    NSMutableDictionary<NSString *, CMUXCEFProfileBridge *> *_byName;
    std::mutex _mutex;
}

+ (instancetype)shared {
    static CMUXCEFProfileRegistryBridge *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[CMUXCEFProfileRegistryBridge alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _byName = [NSMutableDictionary dictionary];
    }
    return self;
}

- (CMUXCEFProfileBridge *)profileForName:(NSString *)name {
    NSCAssert(name.length > 0, @"profile name must be non-empty");
    std::lock_guard<std::mutex> lock(_mutex);

    if (CMUXCEFProfileBridge *existing = _byName[name]) {
        return existing;
    }

    NSString *root = [self resolveProfilesRoot];
    NSString *safe = [self pathSafeName:name];
    NSString *cachePath = [root stringByAppendingPathComponent:safe];

    // Chrome runtime (CEF 146) rejects every CreateContext call that
    // supplies a cache_path under the engine's user_data_dir — see
    // `cef/libcef/browser/chrome/chrome_browser_context.cc:116`
    // ("Cannot create profile at path ...") — and falls back to a
    // half-initialised context. Browsers attached to that context never
    // ship compositor frames, so the pane stays blank.
    //
    // Until a Chrome-runtime-compatible profile factory is wired up
    // (it requires going through `g_browser_process->profile_manager()`
    // rather than CefRequestContext::CreateContext), every profile name
    // shares the global context. cmux loses per-profile cookie / chrome.
    // storage / extension isolation in this state — tracked in the
    // PR description.
    CefRefPtr<CefRequestContext> ctx = CefRequestContext::GetGlobalContext();
    cachePath = [root stringByAppendingPathComponent:@"Default"];

    CMUXCEFProfileBridge *bridge =
        [[CMUXCEFProfileBridge alloc] initWithName:name
                                         cachePath:cachePath
                                           context:ctx];
    _byName[name] = bridge;
    return bridge;
}

- (void)destroyProfileForName:(NSString *)name {
    std::lock_guard<std::mutex> lock(_mutex);
    CMUXCEFProfileBridge *bridge = _byName[name];
    if (!bridge) return;
    [_byName removeObjectForKey:name];
    // CefRequestContext destruction is async; we wait for the CEF UI thread
    // to drop it before nuking the cache dir.
    NSString *cachePath = [bridge.cachePath copy];
    BOOL usesSharedDefaultCache = [[cachePath lastPathComponent] isEqualToString:@"Default"];
    if ([name hasPrefix:@"isolated-"] && !usesSharedDefaultCache) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:cachePath error:nil];
        });
    }
}

- (NSString *)resolveProfilesRoot {
    NSString *root = self.profilesRoot;
    if (root.length > 0) return root;
    // Fallback when the engine hasn't been started yet (unit tests, etc.).
    NSString *appSup = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES) firstObject];
    return [[appSup stringByAppendingPathComponent:@"cmux"]
            stringByAppendingPathComponent:@"CEFRoot/profiles"];
}

- (NSString *)pathSafeName:(NSString *)name {
    NSCharacterSet *unsafe = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:unsafe];
    return [parts componentsJoinedByString:@"_"];
}

@end

// MARK: - Browser bridge

@interface CMUXCEFBrowserBridge ()
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, copy, nullable) NSURL *currentURL;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;
@property (nonatomic, strong, nullable, readwrite) NSWindow *hostingWindow;
@property (nonatomic, strong, nullable, readwrite) NSView *embeddableView;
- (instancetype)initInternal NS_DESIGNATED_INITIALIZER;
- (void)attachBrowserView:(CefRefPtr<CefBrowserView>)view
                   window:(CefRefPtr<CefWindow>)window
            hostingWindow:(NSWindow *)hostingWindow;
- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser
        hostingWindow:(NSWindow *)hostingWindow;
- (void)attachEmbeddableBrowser:(CefRefPtr<CefBrowser>)browser
                    browserView:(CefRefPtr<CefBrowserView>)browserView
                      cefWindow:(CefRefPtr<CefWindow>)cefWindow
                            view:(NSView *)view;
- (void)attachAlloyBrowserParentView:(NSView *)parentView;
- (void)setBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)teardown;
@end

namespace {

// Forward Chromium callbacks back into the Objective-C bridge instance on
// the main thread. Held as a __weak reference inside the C++ object so the
// callback chain never extends the ObjC bridge's lifetime.
class CMUXCEFClient final : public CefClient,
                            public CefDisplayHandler,
                            public CefLoadHandler,
                            public CefLifeSpanHandler {
public:
    explicit CMUXCEFClient(__weak CMUXCEFBrowserBridge *bridge)
        : bridge_(bridge) {}

    // CefClient
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

    // CefDisplayHandler
    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
        NSString *t = [NSString stringWithUTF8String:title.ToString().c_str()];
        __weak __typeof(bridge_) weak = bridge_;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weak) strong = weak;
            if (!strong) return;
            strong.currentTitle = t;
            id<CMUXCEFBrowserBridgeDelegate> delegate = strong.delegate;
            if ([delegate respondsToSelector:@selector(browserBridge:didChangeTitle:)]) {
                [delegate browserBridge:strong didChangeTitle:t];
            }
        });
    }

    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (!frame->IsMain()) return;
        NSString *s = [NSString stringWithUTF8String:url.ToString().c_str()];
        NSURL *u = [NSURL URLWithString:s];
        if (!u) return;
        __weak __typeof(bridge_) weak = bridge_;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weak) strong = weak;
            if (!strong) return;
            strong.currentURL = u;
            id<CMUXCEFBrowserBridgeDelegate> delegate = strong.delegate;
            if ([delegate respondsToSelector:@selector(browserBridge:didChangeURL:)]) {
                [delegate browserBridge:strong didChangeURL:u];
            }
        });
    }

    // CefLoadHandler
    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading,
                              bool canGoBack, bool canGoForward) override {
        __weak __typeof(bridge_) weak = bridge_;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weak) strong = weak;
            if (!strong) return;
            BOOL wasLoading = strong.isLoading;
            strong.isLoading = isLoading;
            strong.canGoBack = canGoBack;
            strong.canGoForward = canGoForward;
            id<CMUXCEFBrowserBridgeDelegate> delegate = strong.delegate;
            if (isLoading && !wasLoading &&
                [delegate respondsToSelector:@selector(browserBridgeDidStartLoading:)]) {
                [delegate browserBridgeDidStartLoading:strong];
            } else if (!isLoading && wasLoading &&
                       [delegate respondsToSelector:@selector(browserBridgeDidFinishLoading:)]) {
                [delegate browserBridgeDidFinishLoading:strong];
            }
        });
    }

    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode, const CefString& errorText,
                     const CefString& failedUrl) override {
        if (!frame->IsMain()) return;
        // ERR_ABORTED is fired during normal navigation cancellation; not an error.
        if (errorCode == ERR_ABORTED) return;
        NSString *msg = [NSString stringWithFormat:@"CEF load error %d (%s) for %s",
                         static_cast<int>(errorCode),
                         errorText.ToString().c_str(),
                         failedUrl.ToString().c_str()];
        NSError *err = [NSError errorWithDomain:@"CMUXCEF.load"
                                           code:static_cast<NSInteger>(errorCode)
                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
        __weak __typeof(bridge_) weak = bridge_;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weak) strong = weak;
            if (!strong) return;
            id<CMUXCEFBrowserBridgeDelegate> delegate = strong.delegate;
            if ([delegate respondsToSelector:@selector(browserBridge:didFailLoad:)]) {
                [delegate browserBridge:strong didFailLoad:err];
            }
        });
    }

    // CefLifeSpanHandler — capture the CefBrowser ref as soon as it exists.
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        __weak __typeof(bridge_) weak = bridge_;
        CefRefPtr<CefBrowser> ref = browser;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weak) strong = weak;
            if (!strong) return;
            [strong setBrowser:ref];
        });
    }

private:
    __weak CMUXCEFBrowserBridge *bridge_;
    IMPLEMENT_REFCOUNTING(CMUXCEFClient);
    DISALLOW_COPY_AND_ASSIGN(CMUXCEFClient);
};

class CMUXCEFBrowserViewDelegate final : public CefBrowserViewDelegate {
public:
    CMUXCEFBrowserViewDelegate() = default;

    cef_runtime_style_t GetBrowserRuntimeStyle() override {
        return CEF_RUNTIME_STYLE_CHROME;
    }

    // cmux owns the browser chrome in SwiftUI. Leaving CEF's Chrome toolbar
    // disabled keeps Path B as a reparentable page-content view instead of
    // asking Chrome runtime to create its own visible browser window.
    ChromeToolbarType GetChromeToolbarType(
        CefRefPtr<CefBrowserView> browser_view) override {
        return CEF_CTT_NONE;
    }
private:
    IMPLEMENT_REFCOUNTING(CMUXCEFBrowserViewDelegate);
    DISALLOW_COPY_AND_ASSIGN(CMUXCEFBrowserViewDelegate);
};

static void CMUXCEFParkCEFWindow(NSWindow *window);

class CMUXCEFWindowDelegate final : public CefWindowDelegate {
public:
    explicit CMUXCEFWindowDelegate(CefRefPtr<CefBrowserView> browser_view)
        : browser_view_(browser_view) {}

    cef_runtime_style_t GetWindowRuntimeStyle() override {
        return CEF_RUNTIME_STYLE_CHROME;
    }

    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        window->SetBounds(CefRect(-30000, -30000, 4000, 4000));
        window->AddChildView(browser_view_);
        // Trigger Show so CEF Chrome runtime spins up the browser process
        // tree. The Swift caller then orderOut + addChildWindow as needed.
        window->Show();
        window->SetBounds(CefRect(-30000, -30000, 4000, 4000));
        CefWindowHandle handle = window->GetWindowHandle();
        if (handle) {
            id obj = (__bridge id)handle;
            if ([obj isKindOfClass:[NSWindow class]]) {
                CMUXCEFParkCEFWindow((NSWindow *)obj);
            } else if ([obj isKindOfClass:[NSView class]]) {
                CMUXCEFParkCEFWindow([(NSView *)obj window]);
            }
        }
    }

    CefRect GetInitialBounds(CefRefPtr<CefWindow>) override {
        return CefRect(-30000, -30000, 4000, 4000);
    }

    // cmux owns the browser chrome; the CEF NSWindow is overlaid as a
    // childWindow on the cmux pane. Tell CEF to create the NSWindow
    // frameless at construction time (not by mutating styleMask after,
    // which destabilises Chromium's compositor) and without standard
    // window buttons (no traffic lights, no titlebar).
    bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
    bool WithStandardWindowButtons(CefRefPtr<CefWindow>) override { return false; }
    bool CanMinimize(CefRefPtr<CefWindow>) override { return false; }
    bool CanMaximize(CefRefPtr<CefWindow>) override { return false; }
    bool CanResize(CefRefPtr<CefWindow>) override { return true; }
    bool CanClose(CefRefPtr<CefWindow>) override { return true; }

private:
    CefRefPtr<CefBrowserView> browser_view_;
    IMPLEMENT_REFCOUNTING(CMUXCEFWindowDelegate);
    DISALLOW_COPY_AND_ASSIGN(CMUXCEFWindowDelegate);
};

static void CMUXCEFParkCEFWindow(NSWindow *window) {
    if (!window) return;
    [window setFrame:NSMakeRect(-30000, -30000, 4000, 4000) display:NO];
    [window setAlphaValue:0.0];
    [window setIgnoresMouseEvents:YES];
    [window setHasShadow:NO];
    window.collectionBehavior =
        NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorMoveToActiveSpace
        | NSWindowCollectionBehaviorIgnoresCycle
        | NSWindowCollectionBehaviorStationary;
    [window orderFront:nil];
}

}  // namespace

@implementation CMUXCEFBrowserBridge {
    CefRefPtr<CefBrowserView> _browserView;
    CefRefPtr<CefWindow> _cefWindow;
    CefRefPtr<CMUXCEFClient> _client;
    CefRefPtr<CefBrowser> _browser;
    // Strong pointer to the NSWindow Chromium owns (the "CefWindow" on
    // the macOS side). Path B reparents `_embeddableView` into the cmux
    // hierarchy, so `_embeddableView.window` switches to cmux's main
    // window — we lose any way back to the CEF NSWindow without
    // stashing it here.
    NSWindow *_cefPlatformWindow;
    // The cmux host NSWindow this browser has been attached to via
    // `addChildWindow`. Set lazily by `attachToHostWindow:`.
    NSWindow *_hostNSWindow;
}
@synthesize hostingWindow = _hostingWindow;
@synthesize embeddableView = _embeddableView;

- (instancetype)init {
    return [self initInternal];
}

- (instancetype)initInternal {
    if ((self = [super init])) {
        _isLoading = NO;
        _canGoBack = NO;
        _canGoForward = NO;
    }
    return self;
}

- (void)attachBrowserView:(CefRefPtr<CefBrowserView>)view
                   window:(CefRefPtr<CefWindow>)window
            hostingWindow:(NSWindow *)hostingWindow {
    _browserView = view;
    _cefWindow = window;
    _hostingWindow = hostingWindow;
}

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser
        hostingWindow:(NSWindow *)hostingWindow {
    _browser = browser;
    _hostingWindow = hostingWindow;
}

- (void)attachEmbeddableBrowser:(CefRefPtr<CefBrowser>)browser
                    browserView:(CefRefPtr<CefBrowserView>)browserView
                      cefWindow:(CefRefPtr<CefWindow>)cefWindow
                            view:(NSView *)view {
    _browser = browser;
    _browserView = browserView;
    _cefWindow = cefWindow;
    _embeddableView = view;
    _cefPlatformWindow = view.window;
}

- (void)attachAlloyBrowserParentView:(NSView *)parentView {
    // Alloy runtime path: the browser's NSView is added by CEF as a
    // subview of `parentView`. We don't expose an embeddableView here —
    // the cmux pane already owns the parentView and the CEF subview
    // lives inside it. The CefBrowser pointer is filled in later by
    // CMUXCEFClient::OnAfterCreated via -setBrowser:.
    _embeddableView = parentView;  // for resize/sync convenience
    _cefPlatformWindow = parentView.window;
}

- (void)setBrowser:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
}

- (void)loadURL:(NSURL *)url {
    if (!_browser || !url) return;
    CefString cefURL;
    cefURL.FromString([[url absoluteString] UTF8String]);
    _browser->GetMainFrame()->LoadURL(cefURL);
}

- (void)goBack {
    if (_browser && _browser->CanGoBack()) _browser->GoBack();
}

- (void)goForward {
    if (_browser && _browser->CanGoForward()) _browser->GoForward();
}

- (void)reload {
    if (_browser) _browser->Reload();
}

- (void)stopLoading {
    if (_browser) _browser->StopLoad();
}

- (void)showDevTools {
    if (!_browser) return;
    CefWindowInfo windowInfo;
    // Chrome runtime DevTools must be Views-hosted; with all-default
    // windowInfo CEF picks a sensible top-level window.
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(windowInfo, /*client*/ nullptr,
                                      settings, /*inspectAt*/ CefPoint());
}

- (void)closeDevTools {
    if (_browser) _browser->GetHost()->CloseDevTools();
}

- (void)close {
    if (_browser) {
        _browser->GetHost()->CloseBrowser(/*force_close*/ true);
    }
    [self teardown];
}

- (void)teardown {
    _browser = nullptr;
    _browserView = nullptr;
    _cefWindow = nullptr;
    _client = nullptr;
    _hostingWindow = nil;
    _cefPlatformWindow = nil;
}

- (void)syncRenderFrameToScreenRect:(NSRect)screenRect {
    // Path B reparent (matches `CMUXCEFDemoApp/main.swift`): the
    // BridgedContentView has been reparented out of CEF's offscreen
    // NSWindow into a cmux SwiftUI container. We deliberately do NOT
    // call `_cefWindow->SetBounds` here — that triggers Chromium to
    // resize its IOSurface to the new rect, clear it, and (because
    // we have no `WasShown()` equivalent in Chrome runtime) never
    // repaint. The result is a black pane.
    //
    // Instead we leave the CEF NSWindow at its initial offscreen
    // 4000x4000 bounds. Chromium keeps the IOSurface at 4000x4000
    // and continues painting page content into it. The reparented
    // BridgedContentView shows the top-left region of that IOSurface
    // clipped to its (much smaller) bounds. This is the same setup
    // the demo uses and is what gets pixels on screen today.
    if (_cefPlatformWindow == nil) return;

    // Optional legacy childWindow path, only when an explicit host
    // window has been attached via `attach(toHost:)`. Path B reparent
    // does not need this — it stays a no-op.
    if (_hostNSWindow != nil && _cefWindow) {
        if (![_hostNSWindow.childWindows containsObject:_cefPlatformWindow]) {
            [_hostNSWindow addChildWindow:_cefPlatformWindow ordered:NSWindowAbove];
        }
        [_cefPlatformWindow setAlphaValue:1.0];
        [_cefPlatformWindow setHasShadow:NO];
        [_cefPlatformWindow setIgnoresMouseEvents:NO];
        for (NSInteger b = NSWindowCloseButton; b <= NSWindowZoomButton; ++b) {
            [[_cefPlatformWindow standardWindowButton:(NSWindowButton)b] setHidden:YES];
        }
        CGFloat screenHeight = [[[NSScreen screens] firstObject] frame].size.height;
        int cefY = (int)(screenHeight - NSMaxY(screenRect));
        CefRect cefRect((int)NSMinX(screenRect), cefY,
                        (int)NSWidth(screenRect), (int)NSHeight(screenRect));
        _cefWindow->SetBounds(cefRect);
    }
}

- (void)attachToHostWindow:(NSWindow *)hostWindow {
    _hostNSWindow = hostWindow;
}

- (void)notifyEmbedHostResizedAndShown {
    if (!_browser) return;
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (!host) return;
    host->WasHidden(false);
    host->WasResized();
    host->Invalidate(PET_VIEW);
    host->SetFocus(true);
}

- (void)setClient:(CefRefPtr<CMUXCEFClient>)client { _client = client; }

@end


@implementation CMUXCEFEngineBridge (BrowserCreation)

- (CMUXCEFBrowserBridge *)createBrowserInProfile:(CMUXCEFProfileBridge *)profile
                                      initialURL:(NSURL *)initialURL
                                           error:(NSError **)error {
    NSCAssert([NSThread isMainThread],
              @"createBrowserInProfile must be called on the main thread");
    if (!self.isInitialized) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CEF is not initialized"}];
        }
        return nil;
    }
    if (!profile) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"profile is nil"}];
        }
        return nil;
    }

    CMUXCEFBrowserBridge *bridge = [[CMUXCEFBrowserBridge alloc] initInternal];
    CefRefPtr<CMUXCEFClient> client(new CMUXCEFClient(bridge));
    [bridge setClient:client];

    // Use CefBrowserHost::CreateBrowserSync with no parent_view and an
    // explicit CEF_RUNTIME_STYLE_CHROME. CEF then constructs a fully-
    // chromed native browser window (tab strip, URL bar, back/forward,
    // extension toolbar, menu, NTP) — the same window structure the user
    // would see in a stock Chromium build. The caller can still hide
    // the OS window via the returned NSWindow + child-window tracking
    // when cmux is ready to dock it inside a pane.
    CefWindowInfo windowInfo;
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    windowInfo.bounds = CefRect(100, 100, 1024, 720);

    CefBrowserSettings browserSettings;
    CefString url;
    url.FromString([[initialURL absoluteString] UTF8String]);

    CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
        windowInfo, client.get(), url, browserSettings,
        /*extra_info*/ nullptr, [profile underlyingContext]);
    if (!browser) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefBrowserHost::CreateBrowserSync returned null"}];
        }
        return nil;
    }

    // On macOS, GetWindowHandle returns the NSView backing the browser
    // content; its window is the Chrome runtime native NSWindow.
    CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
    NSView *contentView = (__bridge NSView *)handle;
    NSWindow *hostingWindow = contentView.window;

    [bridge attachBrowser:browser hostingWindow:hostingWindow];
    return bridge;
}

- (CMUXCEFBrowserBridge *)createEmbeddableBrowserInProfile:(CMUXCEFProfileBridge *)profile
                                                 initialURL:(NSURL *)initialURL
                                                      error:(NSError **)error {
    NSCAssert([NSThread isMainThread],
              @"createEmbeddableBrowserInProfile must be called on the main thread");
    if (!self.isInitialized) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CEF is not initialized"}];
        }
        return nil;
    }
    if (!profile) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"profile is nil"}];
        }
        return nil;
    }

    CMUXCEFBrowserBridge *bridge = [[CMUXCEFBrowserBridge alloc] initInternal];
    CefRefPtr<CMUXCEFClient> client(new CMUXCEFClient(bridge));
    [bridge setClient:client];

    // Build a CefBrowserView via the Views framework, request Chrome
    // runtime style so extension/popup features stay available, then
    // wrap it in a hidden CefWindow so CEF actually instantiates the
    // backing NSView. After that we lift the NSView out of CefWindow's
    // hierarchy and hand it to the caller for cmux pane embedding.
    CefBrowserSettings browserSettings;
    CefString url;
    url.FromString([[initialURL absoluteString] UTF8String]);

    CefRefPtr<CefBrowserView> browserView = CefBrowserView::CreateBrowserView(
        client.get(),
        url,
        browserSettings,
        /*extra_info*/ nullptr,
        [profile underlyingContext],
        new CMUXCEFBrowserViewDelegate());
    if (!browserView) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefBrowserView::CreateBrowserView returned null"}];
        }
        return nil;
    }

    CefRefPtr<CefWindow> cefWindow = CefWindow::CreateTopLevelWindow(
        new CMUXCEFWindowDelegate(browserView));
    if (!cefWindow) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefWindow::CreateTopLevelWindow returned null"}];
        }
        return nil;
    }

    // The CefBrowser becomes available the moment the BrowserView is
    // added to a CefWindow (which happened inside CMUXCEFWindowDelegate::
    // OnWindowCreated). Pull it out so we can ask CefBrowserHost for the
    // ACTUAL render NSView (CefWindow::GetWindowHandle gives the whole
    // Views container, not the browser content).
    CefRefPtr<CefBrowser> browser = browserView->GetBrowser();
    if (!browser) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-5
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefBrowserView produced no CefBrowser"}];
        }
        return nil;
    }
    CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
    NSView *innerView = (__bridge NSView *)handle;
    NSWindow *cefNSWindow = innerView.window;
    if (!innerView || !cefNSWindow) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-6
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefBrowserHost has no NSView yet"}];
        }
        return nil;
    }

    // CEF only ticks its renderer while the CefWindow's NSWindow is
    // ordered on-screen, AND clips the render canvas to the CefWindow
    // frame size. Park it far offscreen at a generous 4000×4000 so the
    // canvas is big enough for any cmux pane. alpha=0 + off-screen +
    // ignoresMouseEvents keeps it from being visible to the user or
    // intercepting events.
    CMUXCEFParkCEFWindow(cefNSWindow);

    // In Chrome runtime the CefWindow host and the browser host can report
    // different Cocoa handles. Park both when present; otherwise CEF may
    // leave behind a visible empty native window while the content view is
    // reparented into cmux.
    id cefWindowHandle = (__bridge id)cefWindow->GetWindowHandle();
    NSWindow *cefTopLevelWindow = nil;
    if ([cefWindowHandle isKindOfClass:[NSWindow class]]) {
        cefTopLevelWindow = (NSWindow *)cefWindowHandle;
    } else if ([cefWindowHandle isKindOfClass:[NSView class]]) {
        cefTopLevelWindow = [(NSView *)cefWindowHandle window];
    }
    if (cefTopLevelWindow && cefTopLevelWindow != cefNSWindow) {
        CMUXCEFParkCEFWindow(cefTopLevelWindow);
    }

    [bridge attachEmbeddableBrowser:browser
                        browserView:browserView
                          cefWindow:cefWindow
                                view:innerView];
    return bridge;
}

#pragma mark - Path C: Alloy runtime + parent_view native embedding

- (CMUXCEFBrowserBridge *)createAlloyBrowserWithParentView:(NSView *)parentView
                                                     bounds:(NSRect)bounds
                                                    profile:(CMUXCEFProfileBridge *)profile
                                                 initialURL:(NSURL *)initialURL
                                                      error:(NSError **)error {
    NSCAssert([NSThread isMainThread],
              @"createAlloyBrowser must be called on the main thread");
    if (!self.isInitialized) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CEF is not initialized"}];
        }
        return nil;
    }
    if (!profile) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"profile is nil"}];
        }
        return nil;
    }
    if (!parentView) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-3
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"parentView is nil"}];
        }
        return nil;
    }

    CMUXCEFBrowserBridge *bridge = [[CMUXCEFBrowserBridge alloc] initInternal];
    CefRefPtr<CMUXCEFClient> client(new CMUXCEFClient(bridge));
    [bridge setClient:client];

    CefWindowInfo windowInfo;
    // SetAsChild forces Alloy runtime (per cef_types_mac.h §runtime_style:
    // "Alloy style will always be used … if |parent_view| is provided.").
    // The CEF browser becomes a regular NSView subview of `parentView`.
    windowInfo.SetAsChild(
        (__bridge cef_window_handle_t)parentView,
        CefRect((int)NSMinX(bounds), (int)NSMinY(bounds),
                (int)NSWidth(bounds), (int)NSHeight(bounds)));
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    CefBrowserSettings browserSettings;
    CefString url;
    url.FromString([[initialURL absoluteString] UTF8String]);

    bool ok = CefBrowserHost::CreateBrowser(
        windowInfo,
        client.get(),
        url,
        browserSettings,
        /*extra_info*/ nullptr,
        [profile underlyingContext]);
    if (!ok) {
        if (error) {
            *error = [NSError errorWithDomain:kCMUXCEFErrorDomain code:-4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"CefBrowserHost::CreateBrowser returned false"}];
        }
        return nil;
    }

    // CreateBrowser is async — the CefBrowser may not be available yet.
    // The client's OnAfterCreated wires up the browser pointer back into
    // the bridge. We return the bridge immediately; cmux can ignore the
    // window-handle accessors until OnAfterCreated fires.
    [bridge attachAlloyBrowserParentView:parentView];
    return bridge;
}

@end
