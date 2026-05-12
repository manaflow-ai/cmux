// CMUXCEFBridge.h — public ObjC-visible bridge between Swift (CMUXCEF)
// and the C++ CEF library. **All** CEF C++ interaction lives behind
// this wall; Swift never touches CefRefPtr, CefBrowser, or any other
// CEF type directly.
//
// Threading: every method declared here is documented for either
// "MainActor only" (UI / lifecycle) or "any thread" (callback registration).
// The Swift side enforces MainActor isolation; the ObjC++ side enforces
// CEF_REQUIRE_UI_THREAD() at the entry points that need it.
//
// Ownership: any object returned with a leading "create" or "new" in its
// name is owned by Swift via a strong reference; ARC keeps it alive. The
// underlying CEF reference is balanced inside the bridge.

#pragma once

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CMUXCEFBrowserBridge;
@class CMUXCEFProfileBridge;

// MARK: - Engine lifecycle

/// Configuration for `CMUXCEFEngineBridge initializeWithConfig:`. Mirrors
/// the relevant subset of CefSettings + cmux's curated extension list.
@interface CMUXCEFEngineConfigBridge : NSObject

/// Absolute path to the root cache dir. Must exist before init.
/// Maps to CefSettings.root_cache_path.
@property (nonatomic, copy) NSString *rootCachePath;

/// Comma-joined absolute paths to unpacked extension directories. Passed
/// to Chromium's command line as --load-extension. Maps onto Chrome's
/// runtime extension subsystem; same extensions are visible to every
/// CefRequestContext in the process. Per-profile *state* (storage,
/// cookies, login) stays isolated.
@property (nonatomic, copy, nullable) NSString *loadExtensionsArg;

/// If non-zero, override CEF's log severity.
/// 0 = default, 1 = verbose, 2 = info, 3 = warning, 4 = error, 5 = fatal.
@property (nonatomic, assign) NSInteger logSeverity;

/// Optional. Forwarded to CefSettings.user_agent_product. cmux brand
/// suffix appears in chrome://version.
@property (nonatomic, copy, nullable) NSString *userAgentProduct;

/// Optional. Absolute path to the directory containing the
/// `Chromium Embedded Framework.framework` and helper .app bundles.
/// When cmux is running inside a proper .app bundle this is left nil
/// and CEF discovers everything via bundle layout. When running outside
/// a bundle (CLI / SwiftPM `swift run`), the caller must set this and
/// the helper paths so CEF can spawn subprocesses and locate
/// `icudtl.dat`.
@property (nonatomic, copy, nullable) NSString *frameworkDirectoryPath;

/// Optional. Absolute path to the helper executable used for GPU /
/// utility / renderer subprocesses. When nil, CEF discovers it via the
/// .app layout convention.
@property (nonatomic, copy, nullable) NSString *browserSubprocessPath;

@end


/// Process-wide singleton that wraps `CefInitialize` / `CefShutdown` and
/// the CefApp subclass that forwards cmux command-line options.
///
/// Lifecycle (called exactly once from the cmux app delegate):
///   1. `+executeSubprocessIfNeeded:argv:` — first thing in main().
///      If this returns non-negative, the process is a CEF helper; exit
///      with that code immediately.
///   2. `[CMUXCEFEngineBridge shared] initializeWithConfig:]` — call
///      from applicationDidFinishLaunching: on the main thread.
///   3. `[CMUXCEFEngineBridge shared] shutdown]` — call from
///      applicationWillTerminate:.
@interface CMUXCEFEngineBridge : NSObject

+ (instancetype)shared;

/// `argc`/`argv` are the values passed to main(). When this returns a
/// non-negative exit code, the current process is a CEF helper (renderer,
/// gpu, utility, etc.) and the caller must exit with that code without
/// touching anything else. When it returns -1, the current process is the
/// browser process and main() should continue normally.
+ (int)executeSubprocessIfNeededWithArgc:(int)argc argv:(char *_Nullable *_Nullable)argv
    NS_SWIFT_NAME(executeSubprocessIfNeeded(argc:argv:));

/// One-shot. Initializes CEF. Returns NO on failure; `error` is populated
/// with a domain "CMUXCEF" code from `CMUXCEFInitError` enum (in the .mm).
- (BOOL)initializeWithConfig:(CMUXCEFEngineConfigBridge *)config
                       error:(NSError **)error;

/// Idempotent. Calls CefShutdown. After this, no further CEF interaction
/// is possible from this process.
- (void)shutdown;

@property (nonatomic, readonly) BOOL isInitialized;

/// Block on the CEF UI message loop. Returns when -quitMessageLoop is
/// called. Use this from a CLI / SwiftPM `swift run` integration test.
/// cmux apps that run AppKit's NSApp.run() should NOT call this; they
/// should instead let CEF integrate via CefDoMessageLoopWork (driven
/// from an NSRunLoop observer — to be exposed in a later phase).
- (void)runMessageLoop;
- (void)quitMessageLoop;

@end

// MARK: - Profile registry

/// One per CEF `CefRequestContext`. Acquired by name; same name returns
/// the same bridge. Owns the underlying cache directory layout.
@interface CMUXCEFProfileBridge : NSObject

/// Stable name (e.g. "default", "work", "isolated-<uuid>"). Path-safe.
@property (nonatomic, readonly) NSString *name;

/// Absolute path to this profile's cache directory. Lives under the
/// engine's root_cache_path.
@property (nonatomic, readonly) NSString *cachePath;

@end


@interface CMUXCEFProfileRegistryBridge : NSObject

+ (instancetype)shared;

/// Engine sets this once during initialize. Profile cache directories
/// are created as `<profilesRoot>/<name>` underneath it. Must satisfy
/// CEF's "cache_path is a child of root_cache_path" rule.
@property (nonatomic, copy, nullable) NSString *profilesRoot;

/// Look up an existing profile bridge or create a new one with the given
/// name. The returned bridge is retained by the registry; callers may
/// hold a strong reference for as long as they need.
- (CMUXCEFProfileBridge *)profileForName:(NSString *)name;

/// Garbage-collect a profile bridge whose backing browsers have all
/// been closed and whose directory is no longer needed. The cache
/// directory is removed from disk after the underlying RequestContext
/// is destroyed.
- (void)destroyProfileForName:(NSString *)name;

@end

// MARK: - Browser instance

/// Delegate that receives navigation / title / loading-state callbacks
/// for a single CEF browser. Methods are invoked on the main thread.
@protocol CMUXCEFBrowserBridgeDelegate <NSObject>
@optional
- (void)browserBridgeDidStartLoading:(CMUXCEFBrowserBridge *)bridge;
- (void)browserBridgeDidFinishLoading:(CMUXCEFBrowserBridge *)bridge;
- (void)browserBridge:(CMUXCEFBrowserBridge *)bridge didChangeTitle:(NSString *)title;
- (void)browserBridge:(CMUXCEFBrowserBridge *)bridge didChangeURL:(NSURL *)url;
- (void)browserBridge:(CMUXCEFBrowserBridge *)bridge didFailLoad:(NSError *)error;
@end


/// A single CEF browser instance. Two embedding modes:
///   * `hostingWindow` — top-level NSWindow path used by
///     `-createBrowserInProfile:initialURL:`. cmux pane reparenting code
///     uses `addChildWindow:` to glue it to a main window.
///   * `embeddableView` — content NSView extracted from the underlying
///     CefBrowserView (Path B). The caller can `addSubview:` this
///     directly into a regular NSView hierarchy.
/// Exactly one of these is non-nil per bridge instance.
@interface CMUXCEFBrowserBridge : NSObject

/// Non-nil when this bridge was created via
/// `-createBrowserInProfile:initialURL:`.
@property (nonatomic, readonly, nullable) NSWindow *hostingWindow;

/// Non-nil when this bridge was created via
/// `-createEmbeddableBrowserInProfile:initialURL:`. The NSView has been
/// removed from CEF's own CefWindow content view; the caller adds it
/// into a cmux NSView hierarchy.
@property (nonatomic, readonly, nullable) NSView *embeddableView;

/// For embeddable browsers: align the internal CefWindow's frame to the
/// embedding container's on-screen rect. CEF computes mouse coordinates
/// and clips its render canvas relative to the CefWindow frame, so the
/// CefWindow must occupy the same screen-space rectangle as the
/// embeddable NSView (even though it's invisible). Call this whenever
/// the embedding container's screen frame changes (resize, divider
/// drag, parent window move, screen change, …).
///
/// No-op if this bridge has no embeddable view.
- (void)syncRenderFrameToScreenRect:(NSRect)screenRect;

/// Tell the bridge which cmux NSWindow this browser should be hosted on
/// via `addChildWindow:`. The CEF NSWindow becomes a borderless child
/// window of this host; `syncRenderFrameToScreenRect:` then positions it
/// to match the cmux pane.
- (void)attachToHostWindow:(NSWindow *)hostWindow;

/// Notify the underlying CefBrowserHost that the embedded NSView has been
/// reparented / resized so Chromium re-queries the view size and pushes a
/// fresh render layer. This is required when the cmux pane mounts the
/// extracted NSView in a SwiftUI hierarchy whose layout is asynchronous —
/// without this, Chromium can latch onto the transient 0×0 frame the view
/// has between `removeFromSuperview` and the first Auto-Layout pass.
- (void)notifyEmbedHostResizedAndShown;

@property (nonatomic, weak, nullable) id<CMUXCEFBrowserBridgeDelegate> delegate;

/// Convenience accessors. May be nil before the browser has loaded
/// its first URL.
@property (nonatomic, readonly, nullable) NSString *currentTitle;
@property (nonatomic, readonly, nullable) NSURL *currentURL;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;

/// Show the CEF DevTools window for this browser. First version uses a
/// new top-level window; docked DevTools comes later.
- (void)showDevTools;
- (void)closeDevTools;

/// Tear down the underlying CEF browser. After this, the bridge is
/// inert. Must be called from the main thread.
- (void)close;

@end

/// Factory — only the engine knows how to wire CefRequestContext +
/// CefBrowserView + CefWindow together correctly.
@interface CMUXCEFEngineBridge (BrowserCreation)

/// Create a new browser inside its own borderless top-level NSWindow,
/// using the given profile's RequestContext. The hosting window is
/// initially hidden; the caller adds it as a child window and calls
/// `orderFront:` / `setFrame:display:` to position and reveal it.
- (nullable CMUXCEFBrowserBridge *)createBrowserInProfile:(CMUXCEFProfileBridge *)profile
                                              initialURL:(NSURL *)initialURL
                                                   error:(NSError **)error;

/// Path B experiment — create a CEF browser inside an internal CefWindow,
/// then extract the inner NSView so it can be re-parented directly into
/// a cmux NSView hierarchy (NSSplitView, Bonsplit pane, etc.).
///
/// On return, the bridge owns:
///   * a hidden CefWindow that keeps the browser alive
///   * a strong reference to the extracted NSView
///
/// The returned NSView has already been removeFromSuperview'd; the caller
/// `addSubview:` into its own container. The browser continues to render
/// inside that NSView even though the NSView is no longer in CEF's own
/// CefWindow content-view tree.
///
/// Returns nil + populates `error` on failure (CEF init not done, profile
/// nil, browser creation failed, NSView extraction failed).
- (nullable CMUXCEFBrowserBridge *)createEmbeddableBrowserInProfile:(CMUXCEFProfileBridge *)profile
                                                          initialURL:(NSURL *)initialURL
                                                               error:(NSError **)error;

/// **Path C — Alloy runtime native NSView embedding.**
///
/// Calls `CefBrowserHost::CreateBrowser` with `CefWindowInfo::SetAsChild(parentView, bounds)`.
/// In CEF 146 this forces Alloy runtime (Chrome runtime cannot embed into an
/// existing NSView — its compositor binds to a dedicated NSWindow). The CEF
/// browser becomes a regular NSView subview of `parentView` and behaves like
/// any AppKit view: layout via Auto Layout, follows split-divider drags,
/// participates in normal hit-testing, no addChildWindow / CARemoteLayer
/// gymnastics.
///
/// Trade-off vs Chrome runtime: Alloy in CEF 146 does NOT expose the Chrome
/// extension subsystem. The browser still has full Chromium rendering, V8,
/// network stack, devtools, etc. Use this when extension support is not
/// required.
- (nullable CMUXCEFBrowserBridge *)createAlloyBrowserWithParentView:(NSView *)parentView
                                                              bounds:(NSRect)bounds
                                                             profile:(CMUXCEFProfileBridge *)profile
                                                          initialURL:(NSURL *)initialURL
                                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
