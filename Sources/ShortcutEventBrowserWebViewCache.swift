import AppKit
import ObjectiveC
import WebKit

/// Keeps the direct browser ownership result for one AppKit event while it
/// crosses the application, window, and web-view key-equivalent boundaries.
/// The cache is attached to the event itself, so it cannot grow with the
/// number of panes or keystrokes and needs no app-wide mutable registry.
final class ShortcutEventBrowserWebViewCache {
    fileprivate static var associationKey: UInt8 = 0

    /// Event associations must not keep a closed auxiliary window or WebView
    /// alive. Ownership is held by the window/panel graph; this cache only
    /// observes it while that graph remains live.
    weak var eventWindow: NSWindow?
    weak var firstResponder: NSResponder?
    weak var webView: CmuxWebView?
    let activeChordPrefix: ShortcutStroke?
    var captureDecision: Bool?

    init(
        eventWindow: NSWindow,
        firstResponder: NSResponder,
        webView: CmuxWebView?,
        activeChordPrefix: ShortcutStroke?
    ) {
        self.eventWindow = eventWindow
        self.firstResponder = firstResponder
        self.webView = webView
        self.activeChordPrefix = activeChordPrefix
    }

    deinit {}

    func matches(
        window: NSWindow,
        responder: NSResponder,
        activeChordPrefix: ShortcutStroke?
    ) -> Bool {
        guard let eventWindow, let firstResponder else { return false }
        return eventWindow === window
            && firstResponder === responder
            && self.activeChordPrefix == activeChordPrefix
    }
}

extension NSEvent {
    var cmuxBrowserWebViewCache: ShortcutEventBrowserWebViewCache? {
        get {
            objc_getAssociatedObject(self, &ShortcutEventBrowserWebViewCache.associationKey)
                as? ShortcutEventBrowserWebViewCache
        }
        set {
            objc_setAssociatedObject(
                self,
                &ShortcutEventBrowserWebViewCache.associationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
