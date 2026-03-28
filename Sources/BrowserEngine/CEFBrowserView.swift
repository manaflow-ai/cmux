import AppKit
import Combine
import Bonsplit

/// An NSView that hosts a CEF (Chromium) browser using Alloy runtime.
/// CEF renders directly inside this view via parent_view.
/// Navigation is controlled by cmux's address bar.
final class CEFBrowserView: NSView {

    private var browserHandle: cef_bridge_browser_t?
    private var profileHandle: cef_bridge_profile_t?
    private var cefChildView: NSView?
    private var callbacksStorage: cef_bridge_client_callbacks?

    private var pendingURL: String?
    private var pendingCachePath: String?
    private var browserCreationAttempted = false

    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    weak var delegate: CEFBrowserViewDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        destroyBrowser()
    }

    // MARK: - Browser Lifecycle

    func createBrowser(initialURL: String, cachePath: String?) {
        guard CEFRuntime.shared.isInitialized else { return }
        guard browserHandle == nil, !browserCreationAttempted else { return }
        pendingURL = initialURL
        pendingCachePath = cachePath
        if bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
    }

    private func createBrowserNow() {
        guard pendingURL != nil, !browserCreationAttempted else { return }
        browserCreationAttempted = true
#if DEBUG
        dlog("cef.createBrowserNow bounds=\(bounds) window=\(window != nil)")
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createBrowserImmediate()
        }
    }

    private func createBrowserImmediate() {
        guard let url = pendingURL else { return }

        if let cachePath = pendingCachePath {
            profileHandle = cef_bridge_profile_create(cachePath)
        }

        var callbacks = cef_bridge_client_callbacks()
        let ud = Unmanaged.passUnretained(self).toOpaque()
        callbacks.user_data = ud
        callbacks.on_title_change = { _, title, ud in
            guard let ud, let title else { return }
            Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                .currentTitle = String(cString: title)
        }
        callbacks.on_url_change = { _, url, ud in
            guard let ud, let url else { return }
            Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                .currentURL = String(cString: url)
        }
        callbacks.on_loading_state_change = { _, loading, back, fwd, ud in
            guard let ud else { return }
            let v = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            v.isLoading = loading
            v.canGoBack = back
            v.canGoForward = fwd
        }
        callbacks.on_navigation = { _, _, _, _ in }
        callbacks.on_fullscreen_change = { _, _, _ in }
        callbacks.on_popup_request = { _, _, _ in false }
        callbacks.on_console_message = { _, _, _, _, _, _ in }
        callbacksStorage = callbacks

        let parentPtr = Unmanaged.passUnretained(self).toOpaque()
        let w = Int32(bounds.width)
        let h = Int32(bounds.height)

        browserHandle = withUnsafePointer(to: &callbacksStorage!) { ptr in
            cef_bridge_browser_create(profileHandle, url, parentPtr, w, h, ptr)
        }

#if DEBUG
        dlog("cef.browser browserHandle=\(browserHandle != nil ? "ok" : "NULL")")
#endif
        guard browserHandle != nil else { return }

        pollForChild()
        pendingURL = nil
        pendingCachePath = nil
    }

    // MARK: - Child View Tracking

    private var pollCount = 0

    private func pollForChild() {
        pollCount += 1
        if let child = subviews.first {
            child.frame = bounds
            child.autoresizingMask = [.width, .height]
            cefChildView = child
#if DEBUG
            dlog("cef.childFound polls=\(pollCount)")
#endif
            return
        }
        if pollCount < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollForChild()
            }
        }
    }

    func destroyBrowser() {
        if let h = browserHandle { cef_bridge_browser_destroy(h); browserHandle = nil }
        if let p = profileHandle { cef_bridge_profile_destroy(p); profileHandle = nil }
        cefChildView?.removeFromSuperview()
        cefChildView = nil
        callbacksStorage = nil
    }

    // MARK: - Navigation

    func loadURL(_ urlString: String) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_load_url(h, urlString)
    }

    func goBack() { if let h = browserHandle { cef_bridge_browser_go_back(h) } }
    func goForward() { if let h = browserHandle { cef_bridge_browser_go_forward(h) } }
    func reload() { if let h = browserHandle { cef_bridge_browser_reload(h) } }
    func stopLoading() { if let h = browserHandle { cef_bridge_browser_stop(h) } }

    func showDevTools() { if let h = browserHandle { cef_bridge_browser_show_devtools(h) } }
    func closeDevTools() { if let h = browserHandle { cef_bridge_browser_close_devtools(h) } }

    func notifyHidden(_ hidden: Bool) { if let h = browserHandle { cef_bridge_browser_set_hidden(h, hidden) } }
    func notifyResized() { if let h = browserHandle { cef_bridge_browser_notify_resized(h) } }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, bounds.width > 0, bounds.height > 0, pendingURL != nil {
            createBrowserNow()
        }
    }

    override func layout() {
        super.layout()
        if pendingURL != nil, !browserCreationAttempted,
           bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
        cefChildView?.frame = bounds
        notifyResized()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cefChildView?.frame = bounds
        notifyResized()
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let child = cefChildView {
            window?.makeFirstResponder(child)
            child.mouseDown(with: event)
        } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let child = cefChildView {
            window?.makeFirstResponder(child)
            child.rightMouseDown(with: event)
        } else { super.rightMouseDown(with: event) }
    }

    override func becomeFirstResponder() -> Bool {
        if let child = cefChildView {
            window?.makeFirstResponder(child)
            return true
        }
        return super.becomeFirstResponder()
    }
}

protocol CEFBrowserViewDelegate: AnyObject {
    func cefBrowserView(_ view: CEFBrowserView, didFailWithError message: String)
}
extension CEFBrowserViewDelegate {
    func cefBrowserView(_ view: CEFBrowserView, didFailWithError message: String) {}
}
