public import AppKit

/// A viewer page's native menu on selected text (the Markdown and editor pages): WebKit's Copy,
/// then a separator and the viewer's rows (Comment…, Quote in Chat, and any a host adds). With
/// nothing selected WebKit offers no Copy, and the menu keeps only the desktop default (empty).
///
/// One editor per page: a host that wants more rows on a file page adds them to ``rows`` instead of
/// setting a second ``PageWebView/contextMenuEditor`` (the last one set wins).
@MainActor
public struct ViewerSelectionMenu {
    /// One row: its title and what it runs.
    public struct Row {
        public var title: String
        public var run: () -> Void

        /// A row titled `title` that runs `run`.
        public init(title: String, run: @escaping () -> Void) {
            self.title = title
            self.run = run
        }
    }

    /// The rows under Copy, in order.
    public var rows: [Row]

    /// A menu with `rows` under Copy.
    public init(rows: [Row]) {
        self.rows = rows
    }

    /// Edits WebKit's default `menu` in place: the desktop items (Copy), then the rows.
    public func apply(to menu: NSMenu) {
        PageWKWebView.keepDesktopItems(in: menu)
    }

    /// Makes this menu `page`'s context menu.
    public func install(on page: PageWebView) {
        let menu = self
        page.contextMenuEditor = { menu.apply(to: $0) }
    }

    /// The localized titles of the viewer rows.
    public enum Titles {
        /// "Comment…": opens the comment popover.
        public static var comment: String {
            String(localized: "pages.viewerSelection.comment", defaultValue: "Comment…", bundle: .module)
        }

        /// "Quote in Chat": sends the selection with no comment.
        public static var quoteInChat: String {
            String(localized: "pages.viewerSelection.quoteInChat", defaultValue: "Quote in Chat", bundle: .module)
        }
    }
}
