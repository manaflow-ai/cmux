import AppKit
import WebKit

/// `WKWebView` with cmux context menu wording. App shortcuts reach the host
/// before the page: the host routes system and navigation keys app-wide and
/// content keys in its window, before any view (the page is in-window).
final class WebKitWebView: WKWebView {
    weak var owner: WebKitTab?
    /// The last mouse-down or key-down the user gave this view: a page may
    /// enter pane fullscreen only shortly after one (transient activation).
    private(set) var lastUserInput: ContinuousClock.Instant?

    override func mouseDown(with event: NSEvent) {
        lastUserInput = .now
        owner?.automaticDownloads.userGesture()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastUserInput = .now
        owner?.automaticDownloads.userGesture()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        lastUserInput = .now
        owner?.automaticDownloads.userGesture()
        super.otherMouseDown(with: event)
    }

    /// Escape always leaves pane fullscreen, whatever the page does with
    /// the key (a page can swallow it before the shim sees it).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let owner, owner.state.isContentFullscreen {
            owner.leaveContentFullscreen()
            return
        }
        lastUserInput = .now
        owner?.automaticDownloads.userGesture()
        super.keyDown(with: event)
    }

    /// Whether the user gave input within `window` (default: Chromium's
    /// 5-second transient activation).
    func hadRecentUserInput(within window: Duration = .seconds(5)) -> Bool {
        lastUserInput.map { ContinuousClock.now - $0 <= window } ?? false
    }

    /// The host's link, image and selection rows replace WebKit's
    /// (`adjustContextMenu`); WebKit's other "Open … in New Window" items
    /// open cmux tabs (the request arrives at `createWebViewWith`), so they
    /// are renamed to match.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        adjustContextMenu(menu)
    }

    /// The host rows for the last right-click's hit (none when the hit
    /// script did not report, such as on a PDF: WebKit's rows stay) and
    /// the renames.
    func adjustContextMenu(_ menu: NSMenu) {
        if let owner, owner.hasDelegate, let hit = owner.takeContextHit() {
            WebKitContextHit.removeEngineRows(from: menu, for: hit)
            owner.emit(.contextMenu(BrowserContextMenuRequest(
                items: [], target: hit, location: .zero,
                insertLeading: { [weak menu] rows in if let menu { WebKitContextHit.insert(rows, into: menu) } },
                completion: { _ in }
            )))
        }
        for item in menu.items {
            switch item.identifier?.rawValue {
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
