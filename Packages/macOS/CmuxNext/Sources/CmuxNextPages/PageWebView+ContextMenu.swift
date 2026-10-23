public import AppKit

extension PageWebView {
    /// Builds the page's native context menu from WebKit's default items. Nil keeps the desktop
    /// default (Copy on a selection, ``PageWKWebView/keepDesktopItems(in:)``); a host that offers
    /// its own items (the agent pane's Copy Message) sets it and keeps the menu desktop-like itself.
    public var contextMenuEditor: (@MainActor (NSMenu) -> Void)? {
        get { webView.contextMenuEditor }
        set { webView.contextMenuEditor = newValue }
    }

    /// Keeps WebKit's desktop default items in `menu` (Copy on a selection): what a page without a
    /// ``contextMenuEditor`` shows. An editor that adds items calls it first.
    public static func keepDefaultMenuItems(in menu: NSMenu) {
        PageWKWebView.keepDesktopItems(in: menu)
    }

    /// The title of Copy in a Chromium page's menu (WebKit titles its own).
    public static var copyTitle: String {
        String(localized: "pages.chromiumMenu.copy", defaultValue: "Copy", bundle: .module)
    }

    /// A menu item titled `title` that runs `handler` (the item keeps the handler alive).
    public static func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        PageMenuAction.item(title, handler: handler)
    }
}
