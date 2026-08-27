import AppKit
import WebKit

@MainActor
extension AppDelegate {
    func browserInspectorOwningWebView(for responder: NSResponder?, in window: NSWindow, event: NSEvent?) -> CmuxWebView? {
        guard cmuxIsLikelyWebInspectorResponder(responder) else { return nil }
        guard let event,
              WindowInputRoutingContext(event: event).allowsFirstResponderHitTesting,
              browserInspectorPointerEventTargets(event, window) else {
            return nil
        }
        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(event.locationInWindow, in: window)
            as? CmuxWebView {
            return webView
        }
        guard let responder else { return nil }
        guard let browserPanel = browserPanelOwningInspectorResponder(responder) else {
            return nil
        }
        return browserPanel.webView as? CmuxWebView
    }

    func postBrowserInspectorClickIntentIfNeeded(for responder: NSResponder?, in window: NSWindow, event: NSEvent?) {
        guard let webView = browserInspectorOwningWebView(for: responder, in: window, event: event) else { return }
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: webView)
    }

    func browserPanelOwningInspectorResponder(_ responder: NSResponder) -> BrowserPanel? {
        for browserPanel in browserPanelsForInspectorFocusHandoff() {
            guard let frontendWebView = browserPanel.webView.cmuxInspectorFrontendWebView(),
                  browserInspectorResponder(responder, belongsTo: frontendWebView) else {
                continue
            }
            return browserPanel
        }
        return nil
    }

    private func browserInspectorPointerEventTargets(_ event: NSEvent, _ window: NSWindow) -> Bool {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return false
        }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }
        return true
    }

    private func browserInspectorResponder(_ responder: NSResponder, belongsTo frontendWebView: WKWebView) -> Bool {
        if responder === frontendWebView { return true }
        if let view = responder as? NSView,
           view === frontendWebView || view.isDescendant(of: frontendWebView) {
            return true
        }

        var current = responder.nextResponder
        var hops = 0
        while let next = current, hops < 64 {
            if next === frontendWebView { return true }
            if let view = next as? NSView,
               view === frontendWebView || view.isDescendant(of: frontendWebView) {
                return true
            }
            current = next.nextResponder
            hops += 1
        }
        return false
    }
}
