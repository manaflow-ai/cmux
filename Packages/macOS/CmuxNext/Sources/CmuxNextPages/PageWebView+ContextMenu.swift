public import AppKit

extension PageWebView {
    /// Builds the page's native context menu from WebKit's default items. Nil keeps the desktop
    /// default (Copy on a selection, ``PageWKWebView/keepDesktopItems(in:)``); a host that offers
    /// its own items (the agent pane's Copy Message) sets it and keeps the menu desktop-like itself.
    public var contextMenuEditor: (@MainActor (NSMenu) -> Void)? {
        get { webView.contextMenuEditor }
        set { webView.contextMenuEditor = newValue }
    }
}
