import AppKit
import ObjectiveC
import WebKit

private var shortcutEventBrowserWebViewCacheKey: UInt8 = 0

/// Keeps the direct browser ownership result for one AppKit event while it
/// crosses the application, window, and web-view key-equivalent boundaries.
/// The cache is attached to the event itself, so it cannot grow with the
/// number of panes or keystrokes and needs no app-wide mutable registry.
final class ShortcutEventBrowserWebViewCache {
    let eventWindow: NSWindow
    let firstResponder: NSResponder
    let webView: CmuxWebView?
    var captureDecision: Bool?

    init(
        eventWindow: NSWindow,
        firstResponder: NSResponder,
        webView: CmuxWebView?
    ) {
        self.eventWindow = eventWindow
        self.firstResponder = firstResponder
        self.webView = webView
    }

    func matches(window: NSWindow, responder: NSResponder) -> Bool {
        eventWindow === window && firstResponder === responder
    }
}

extension NSEvent {
    var cmuxBrowserWebViewCache: ShortcutEventBrowserWebViewCache? {
        get {
            objc_getAssociatedObject(self, &shortcutEventBrowserWebViewCacheKey)
                as? ShortcutEventBrowserWebViewCache
        }
        set {
            objc_setAssociatedObject(
                self,
                &shortcutEventBrowserWebViewCacheKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
