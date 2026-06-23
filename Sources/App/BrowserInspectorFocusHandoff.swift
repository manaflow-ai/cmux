import AppKit
import WebKit

@MainActor
enum BrowserInspectorFocusHandoff {
    static func owningWebView(for responder: NSResponder?, in window: NSWindow, event: NSEvent?) -> CmuxWebView? {
        guard cmuxIsLikelyWebInspectorResponder(responder) else { return nil }
        if let event,
           WindowInputRoutingContext(event: event).allowsFirstResponderHitTesting,
           pointerEventTargets(event, window),
           let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(event.locationInWindow, in: window)
                as? CmuxWebView {
            return webView
        }
        guard let responder else { return nil }
        guard let browserPanel = AppDelegate.shared?.browserPanelOwningInspectorResponder(responder) else {
            return nil
        }
        return browserPanel.webView as? CmuxWebView
    }

    static func postClickIntentIfNeeded(for responder: NSResponder?, in window: NSWindow, event: NSEvent?) {
        guard let webView = owningWebView(for: responder, in: window, event: event) else { return }
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: webView)
    }
}

private extension AppDelegate {
    func browserPanelOwningInspectorResponder(_ responder: NSResponder) -> BrowserPanel? {
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    guard let browserPanel = panel as? BrowserPanel,
                          let frontendWebView = browserPanel.webView.cmuxInspectorFrontendWebView(),
                          BrowserInspectorFocusHandoff.responder(responder, belongsTo: frontendWebView) else {
                        continue
                    }
                    return browserPanel
                }
            }
        }
        return nil
    }
}

private extension BrowserInspectorFocusHandoff {
    static func pointerEventTargets(_ event: NSEvent, _ window: NSWindow) -> Bool {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return false
        }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }
        return true
    }

    static func responder(_ responder: NSResponder, belongsTo frontendWebView: WKWebView) -> Bool {
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
