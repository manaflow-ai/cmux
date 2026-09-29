import AppKit
import WebKit

/// `WKWebView` with cmux key routing and context menu wording.
final class WebKitWebView: WKWebView {
    weak var owner: WebKitTab?

    /// App shortcuts run before the page sees the key equivalent. The check is
    /// limited to a focused web view, because AppKit offers key equivalents
    /// to every view in the window.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if hasKeyboardFocus, let owner, owner.routeKeyEquivalent(event) == .handledByHost {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// "Open Link in New Window" opens a cmux tab (the request arrives at
    /// `createWebViewWith`), so it is renamed to match.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                item.title = Strings.openLinkInNewTab
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = Strings.openImageInNewTab
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = Strings.openVideoInNewTab
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.isHidden = true
            default:
                break
            }
        }
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}

/// Breaks the retain cycle between `WKUserContentController` (which retains
/// its handlers) and the tab.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
