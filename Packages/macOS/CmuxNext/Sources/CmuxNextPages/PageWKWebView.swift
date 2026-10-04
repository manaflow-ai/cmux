import AppKit
import WebKit

/// The WebKit view of every first-party page (DESKTOP-FEEL, R139): the host half of the shared
/// desktop layer (the web half is webviews/src/pages/shared/desktop.ts). A page is app chrome:
/// - no pinch or smart magnification (the UI scale comes from the app);
/// - the native context menu offers only Copy, and only on a selection (a page that draws its own
///   menu cancels `contextmenu`, so WebKit shows none);
/// - Select All acts only inside the focused field, never over the whole page.
/// Swipe navigation and link previews are off in ``PageWebView``. Third-party pages in browser tabs
/// use their own views and are not affected.
final class PageWKWebView: WKWebView {
    /// The context menu items a page keeps: Copy (WebKit adds it only when there is a selection).
    static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy"]

    /// Selects the text of the focused field; does nothing when no field has focus.
    static let selectAllScript = """
    (() => {
      const el = document.activeElement;
      if (!el) return false;
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { el.select(); return true; }
      if (el.isContentEditable) { document.execCommand('selectAll'); return true; }
      return false;
    })()
    """

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsMagnification = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        Self.keepDesktopItems(in: menu)
        super.willOpenMenu(menu, with: event)
    }

    /// Removes every item but Copy (and the separators around removed items).
    static func keepDesktopItems(in menu: NSMenu) {
        for item in menu.items.reversed() where !keptMenuItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
    }

    override func selectAll(_ sender: Any?) {
        evaluateJavaScript(Self.selectAllScript, completionHandler: nil)
    }

    override func magnify(with event: NSEvent) {}

    override func smartMagnify(with event: NSEvent) {}
}
