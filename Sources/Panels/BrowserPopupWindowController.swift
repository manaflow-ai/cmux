import AppKit
import Bonsplit
import ObjectiveC
import WebKit

/// Key for retaining popup controller via objc_setAssociatedObject on the NSPanel.
private var popupControllerKey: UInt8 = 0

/// A floating popup window for `window.open()` requests.
///
/// Hosts a `WKWebView` created with WebKit's pre-configured `WKWebViewConfiguration`
/// to maintain the opener↔popup bridge (`window.opener`, `postMessage`).
/// The provided configuration's `processPool` and `websiteDataStore` are never replaced —
/// WebKit uses them internally for the opener relationship.
@MainActor
final class BrowserPopupWindowController: NSWindowController, NSWindowDelegate {
    static let maxNestingDepth = 3

    let popupWebView: WKWebView
    private let depth: Int
    private var uiDelegate: PopupUIDelegate?
    private var navigationDelegate: PopupNavigationDelegate?
    private var titleObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures, depth: Int = 0) {
        // Safe additive config — do NOT touch processPool or websiteDataStore
#if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
#endif
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        self.depth = depth

        // Use CmuxWebView so app-level shortcuts (Cmd+W, Cmd+N, etc.) aren't swallowed by WebKit.
        let webView = CmuxWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.customUserAgent = BrowserUserAgentSettings.safariUserAgent
        self.popupWebView = webView

        // Size from windowFeatures or default
        let width = windowFeatures.width?.doubleValue ?? 800
        let height = windowFeatures.height?.doubleValue ?? 600
        let rect = NSRect(x: 0, y: 0, width: max(width, 200), height: max(height, 150))

        // No .nonactivatingPanel — the popup must accept keyboard focus for OAuth form input.
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Popup"
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.hidesOnDeactivate = false
        // .normal level — popup doesn't stay above other apps when cmux is inactive.
        panel.level = .normal

        // Position from windowFeatures, clamped to visible screen area.
        // Use the key window's screen (where cmux is) rather than NSScreen.main (primary display).
        if let x = windowFeatures.x?.doubleValue,
           let y = windowFeatures.y?.doubleValue {
            var origin = NSPoint(x: x, y: y)
            if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                origin.x = min(max(origin.x, visible.minX), visible.maxX - rect.width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - rect.height)
            }
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        super.init(window: panel)
        panel.delegate = self

        // Update title bar from page title. KVO can fire off-main, so dispatch.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak panel] _, change in
            let title = change.newValue ?? nil
            DispatchQueue.main.async {
                if let title, !title.isEmpty {
                    panel?.title = title
                }
            }
        }

        // UI delegate for webViewDidClose and nested popups
        let popupUI = PopupUIDelegate()
        popupUI.onClose = { @MainActor [weak self] in self?.closePopup() }
        popupUI.onOpenPopup = { @MainActor [weak self] config, features in
            self?.openNestedPopup(configuration: config, windowFeatures: features)
        }
        webView.uiDelegate = popupUI
        self.uiDelegate = popupUI

        // Navigation delegate for external URL and insecure HTTP handling
        let popupNav = PopupNavigationDelegate()
        webView.navigationDelegate = popupNav
        self.navigationDelegate = popupNav

        panel.makeKeyAndOrderFront(nil)

        // Self-retain via associated object on our own window.
        // Released in windowWillClose.
        objc_setAssociatedObject(panel, &popupControllerKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

#if DEBUG
        dlog("browser.popup.init width=\(Int(width)) height=\(Int(height))")
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func closePopup() {
#if DEBUG
        dlog("browser.popup.close")
#endif
        // Cleanup happens in windowWillClose — don't nil the associated object here,
        // because that drops self-retention before window?.close() triggers windowWillClose.
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        titleObservation?.invalidate()
        titleObservation = nil
        // Symmetric cleanup
        if let win = window {
            objc_setAssociatedObject(win, &popupControllerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
#if DEBUG
        dlog("browser.popup.windowWillClose")
#endif
    }

    // MARK: - Nested popups

    private func openNestedPopup(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let nextDepth = depth + 1
        guard nextDepth <= Self.maxNestingDepth else {
#if DEBUG
            dlog("browser.popup.nested.blocked depth=\(nextDepth) max=\(Self.maxNestingDepth)")
#endif
            return nil
        }
        // Controller self-retains in its init via objc_setAssociatedObject.
        let nested = BrowserPopupWindowController(
            configuration: configuration,
            windowFeatures: windowFeatures,
            depth: nextDepth
        )
#if DEBUG
        dlog("browser.popup.nested depth=\(nextDepth)")
#endif
        return nested.popupWebView
    }
}

// MARK: - PopupUIDelegate

/// Minimal WKUIDelegate for popup windows — handles `window.close()` and nested popups.
@MainActor
private class PopupUIDelegate: NSObject, WKUIDelegate {
    var onClose: (@MainActor () -> Void)?
    var onOpenPopup: (@MainActor (_ config: WKWebViewConfiguration, _ features: WKWindowFeatures) -> WKWebView?)?

    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // External URLs → system handler
        if let url = navigationAction.request.url,
           browserShouldOpenURLExternally(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        return onOpenPopup?(configuration, windowFeatures)
    }
}

// MARK: - PopupNavigationDelegate

/// WKNavigationDelegate for popup windows — handles external URL schemes
/// and insecure HTTP navigation (matching the main browser's guards).
@MainActor
private class PopupNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           browserShouldOpenURLExternally(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Match main browser's insecure HTTP guard
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           browserShouldBlockInsecureHTTPURL(url) {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}
