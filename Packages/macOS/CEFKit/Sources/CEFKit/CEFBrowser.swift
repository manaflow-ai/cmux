import AppKit
import CCEF
import Foundation

/// A CEF browser embedded in a parent NSView. Create only after
/// `CEFApp.shared.onContextInitialized` has fired.
public final class CEFBrowser {
    let ptr: UnsafeMutablePointer<cef_browser_t>
    private let client: CEFClientImpl
    private(set) var isClosed = false
    /// Keeps the profile's request context alive as long as the browser.
    public internal(set) var profile: CEFProfile?
    /// The parent view the browser was created in; used to detach the
    /// browser's view from the window before close (see close()).
    weak var hostView: NSView?

    /// Receives lifecycle and state callbacks on the main thread.
    public var delegate: CEFBrowserDelegate? {
        get { client.delegate }
        set { client.delegate = newValue }
    }

    /// Asynchronously creates a browser as a child of `parentView`. CEF adds
    /// its own NSView subview sized to `frame`; host it in a
    /// CEFBrowserContainerView to keep it sized to the parent's bounds.
    /// `profile: nil` uses the default (global) profile. Creation is async
    /// because request contexts (profiles) initialize asynchronously; using
    /// the synchronous variant with a fresh profile is a fatal CEF error.
    /// `completion` runs on the main thread.
    public static func create(
        in parentView: NSView,
        frame: CGRect,
        url: String,
        profile: CEFProfile? = nil,
        delegate: CEFBrowserDelegate? = nil,
        completion: @escaping (CEFBrowser?) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard CEFApp.shared.isContextInitialized else {
            completion(nil)
            return
        }

        let clientImpl = CEFClientImpl()
        clientImpl.delegate = delegate
        let profileRef = profile
        // Keeps the pump backstop running while creation is in flight (the
        // browser is not counted live until on_after_created).
        CEFApp.shared.browserCreationDidStart()
        clientImpl.onBrowserCreated = { [weak parentView] browser in
            CEFApp.shared.browserCreationDidSettle()
            browser.profile = profileRef
            browser.hostView = parentView
            CEFDebugDump.scheduleDump(for: browser, label: url)
            completion(browser)
        }
        let clientPtr = clientImpl.makeClientStruct()

        var windowInfo = Self.childWindowInfo(parentView: parentView, frame: frame)
        var browserSettings = cef_browser_settings_t()
        browserSettings.size = numericCast(MemoryLayout<cef_browser_settings_t>.size)

        // CEF C API ownership: passing a ref-counted struct as a function
        // argument transfers one reference to the callee. The client's
        // initial reference is intentionally handed over, but the profile's
        // context is kept by CEFProfile, so its reference must be balanced
        // before every pass. Omitting this add_ref frees the context wrapper
        // out from under the profile (fatal "UnwrapDerived called with
        // unexpected class type" on the next use).
        if let contextPtr = profile?.contextPtr {
            cefAddRef(UnsafeMutableRawPointer(contextPtr))
        }
        let started = withCEFString(url) { urlPtr in
            CEFRuntime.createBrowser(
                &windowInfo,
                clientPtr,
                urlPtr,
                &browserSettings,
                nil,
                profile?.contextPtr
            )
        }
        if started != 1 {
            // No reference balancing here: cef_browser_host_create_browser
            // wraps its ref-counted arguments (client, request context) into
            // CefRefPtr on entry, so the transferred references are consumed
            // and released by libcef even when it returns 0.
            CEFApp.shared.browserCreationDidSettle()
            completion(nil)
        }
    }

    /// Opens `url` in a CEF-managed Chrome-style window (real Chrome window
    /// UI: toolbar, omnibox, extension icons). This is the only surface where
    /// WebUI management pages work — Alloy-style embedded browsers block
    /// chrome://extensions and friends by design (CEF issue #3859) — and the
    /// only one with the full Chrome extension UI. The window's lifecycle is
    /// owned by CEF/Chromium, not the app; it still counts as a live browser
    /// for the quit-time drain. Shares cookies/extensions with embedded
    /// browsers created against the same `profile`. `completion` runs on the
    /// main thread with the created browser (nil on failure).
    public static func openChromeStyleWindow(
        url: String,
        profile: CEFProfile? = nil,
        completion: @escaping (CEFBrowser?) -> Void = { _ in }
    ) {
        precondition(Thread.isMainThread)
        guard CEFApp.shared.isContextInitialized else {
            completion(nil)
            return
        }

        let clientImpl = CEFClientImpl()
        let profileRef = profile
        CEFApp.shared.browserCreationDidStart()
        clientImpl.onBrowserCreated = { browser in
            CEFApp.shared.browserCreationDidSettle()
            browser.profile = profileRef
            completion(browser)
        }
        let clientPtr = clientImpl.makeClientStruct()

        var windowInfo = cef_window_info_t()
        windowInfo.size = numericCast(MemoryLayout<cef_window_info_t>.size)
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME
        var browserSettings = cef_browser_settings_t()
        browserSettings.size = numericCast(MemoryLayout<cef_browser_settings_t>.size)

        // Same ownership contract as create(): balance the kept profile
        // context reference before transferring it.
        if let contextPtr = profile?.contextPtr {
            cefAddRef(UnsafeMutableRawPointer(contextPtr))
        }
        let started = withCEFString(url) { urlPtr in
            CEFRuntime.createBrowser(
                &windowInfo,
                clientPtr,
                urlPtr,
                &browserSettings,
                nil,
                profile?.contextPtr
            )
        }
        if started != 1 {
            CEFApp.shared.browserCreationDidSettle()
            completion(nil)
        }
    }

    static func childWindowInfo(parentView: NSView, frame: CGRect) -> cef_window_info_t {
        var windowInfo = cef_window_info_t()
        windowInfo.size = numericCast(MemoryLayout<cef_window_info_t>.size)
        windowInfo.bounds = cef_rect_t(
            x: Int32(frame.origin.x),
            y: Int32(frame.origin.y),
            width: Int32(max(frame.width, 1)),
            height: Int32(max(frame.height, 1))
        )
        windowInfo.parent_view = Unmanaged.passUnretained(parentView).toOpaque()
        // Chrome bootstrap forces Alloy style for parent_view embedding; the
        // extension system still runs, only Chrome's own window UI is absent.
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        return windowInfo
    }

    init(retaining ptr: UnsafeMutablePointer<cef_browser_t>, client: CEFClientImpl) {
        cefAddRef(UnsafeMutableRawPointer(ptr))
        self.ptr = ptr
        self.client = client
    }

    deinit {
        if !isClosed {
            cefRelease(UnsafeMutableRawPointer(ptr))
        }
    }

    // MARK: Navigation

    /// Navigates the main frame to `url`.
    public func load(url: String) {
        guard !isClosed, let frame = ptr.pointee.get_main_frame?(ptr) else { return }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        withCEFString(url) { frame.pointee.load_url?(frame, $0) }
    }

    /// The main frame's current URL; nil once the browser has closed.
    public var url: String? {
        guard !isClosed, let frame = ptr.pointee.get_main_frame?(ptr) else { return nil }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        return String(consumingCEFUserFree: frame.pointee.get_url?(frame))
    }

    /// Whether back navigation is available.
    public var canGoBack: Bool { !isClosed && ptr.pointee.can_go_back?(ptr) != 0 }
    /// Whether forward navigation is available.
    public var canGoForward: Bool { !isClosed && ptr.pointee.can_go_forward?(ptr) != 0 }

    /// Runs after each main-frame load completes.
    public var onLoadEnd: ((CEFBrowser) -> Void)? {
        get { client.onLoadEnd }
        set { client.onLoadEnd = newValue }
    }

    /// Executes script in the main frame's JS context.
    public func executeJavaScript(_ script: String, scriptURL: String = "cefkit://script") {
        guard !isClosed, let frame = ptr.pointee.get_main_frame?(ptr) else { return }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        withCEFString(script) { scriptPtr in
            withCEFString(scriptURL) { urlPtr in
                frame.pointee.execute_java_script?(frame, scriptPtr, urlPtr, 0)
            }
        }
    }

    /// Navigates back in session history.
    public func goBack() { guard !isClosed else { return }; ptr.pointee.go_back?(ptr) }
    /// Navigates forward in session history.
    public func goForward() { guard !isClosed else { return }; ptr.pointee.go_forward?(ptr) }
    /// Reloads the current page.
    public func reload() { guard !isClosed else { return }; ptr.pointee.reload?(ptr) }
    /// Cancels the in-flight load, if any.
    public func stopLoad() { guard !isClosed else { return }; ptr.pointee.stop_load?(ptr) }

    // MARK: Host

    /// CEF's per-browser id; stable across close (cached at destruction).
    public var identifier: Int32 {
        guard !isClosed else { return cachedIdentifier }
        return ptr.pointee.get_identifier?(ptr) ?? 0
    }

    private var cachedIdentifier: Int32 = 0

    /// Gives or removes keyboard focus for the browser view.
    public func setFocus(_ focused: Bool) {
        withHost { $0.pointee.set_focus?($0, focused ? 1 : 0) }
    }

    /// Tells Chromium whether this browser is currently visible to the user.
    public func setHidden(_ hidden: Bool) {
        withHost { $0.pointee.was_hidden?($0, hidden ? 1 : 0) }
    }

    /// Requests browser close; `browserDidClose` fires when destruction
    /// completes.
    ///
    /// The browser's NSView is detached from the window first: closing a CEF
    /// 146 browser while its view is still in a live window over-releases
    /// the host NSWindow, which later crashes as a zombie (objc_zombie
    /// "NSWindow received -retain") when anything touches that window —
    /// reproduced deterministically by the Demo's devtools,resize stress and
    /// cured by detaching before close.
    public func close(force: Bool = false) {
        guard !isClosed else { return }
        if let hostView, hostView.window != nil {
            for subview in hostView.subviews {
                subview.removeFromSuperview()
            }
        }
        withHost { $0.pointee.close_browser?($0, force ? 1 : 0) }
    }

    /// Marks destruction complete (on_before_close) and drops the wrapper's
    /// reference immediately. Holding cef struct references past shutdown is
    /// a fatal CEF DCHECK inside cef_shutdown, and host apps may keep
    /// CEFBrowser objects alive (in dictionaries, controllers) long after the
    /// browser is gone.
    func markClosed() {
        guard !isClosed else { return }
        cachedIdentifier = ptr.pointee.get_identifier?(ptr) ?? 0
        isClosed = true
        cefRelease(UnsafeMutableRawPointer(ptr))
    }

    // MARK: DevTools

    /// Opens DevTools in CEF's own native (Chrome-style) window.
    ///
    /// WARNING: in CEF 146 the chrome-style DevTools window is unstable under
    /// host-window churn — closing it while the app's windows are resizing
    /// reliably produces an NSWindow use-after-free inside Chromium
    /// (objc_zombie "received -retain" abort, reproduced by
    /// Demo CEFDEMO_STRESS_MODE=devtools,resize). Prefer
    /// CEFDevToolsWindow.open, which hosts the DevTools frontend in an
    /// app-owned NSWindow and does not use the chrome window layer. Docked
    /// DevTools must use openDockedDevTools regardless: CEF cannot parent
    /// a DevTools browser to a native view on macOS (DevTools must be Chrome
    /// style, and Chrome style with a native parent is unsupported there,
    /// CEF issue #3294; violating this is a fatal CEF DCHECK).
    public func showDevToolsWindow() {
        var windowInfo = cef_window_info_t()
        windowInfo.size = numericCast(MemoryLayout<cef_window_info_t>.size)
        var browserSettings = cef_browser_settings_t()
        browserSettings.size = numericCast(MemoryLayout<cef_browser_settings_t>.size)
        withHost { host in
            host.pointee.show_dev_tools?(host, &windowInfo, nil, &browserSettings, nil)
        }
    }

    /// Closes CEF-native DevTools opened via showDevToolsWindow.
    public func closeDevTools() {
        withHost { $0.pointee.close_dev_tools?($0) }
    }

    /// Whether CEF-native DevTools is currently shown for this browser.
    public var hasDevTools: Bool {
        var result = false
        withHost { result = $0.pointee.has_dev_tools?($0) != 0 }
        return result
    }

    func withHost(_ body: (UnsafeMutablePointer<cef_browser_host_t>) -> Void) {
        guard !isClosed, let host = ptr.pointee.get_host?(ptr) else { return }
        defer { cefRelease(UnsafeMutableRawPointer(host)) }
        body(host)
    }

    // MARK: Live-browser registry (weak), for graceful shutdown

    private static let liveBrowsers = NSHashTable<CEFBrowser>.weakObjects()

    static func registerLiveBrowser(_ browser: CEFBrowser) {
        liveBrowsers.add(browser)
    }

    static func unregisterLiveBrowser(_ browser: CEFBrowser) {
        liveBrowsers.remove(browser)
    }

    static func forceCloseAllLiveBrowsers() {
        for browser in liveBrowsers.allObjects {
            browser.close(force: true)
        }
    }
}

/// Host view for an embedded browser: keeps the CEF-created child view sized
/// to its own bounds.
public final class CEFBrowserContainerView: NSView {
    /// Flipped so the CEF child view's top-left origin matches Chromium's
    /// coordinate expectations.
    public override var isFlipped: Bool { true }

    /// Keeps the CEF-created child view sized to this view's bounds.
    public override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
