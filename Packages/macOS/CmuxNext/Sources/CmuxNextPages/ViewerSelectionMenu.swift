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
    /// The page's own items after the rows (the Markdown page's Reset Column Widths), run on every
    /// menu, with or without a selection.
    public var then: (@MainActor (NSMenu) -> Void)?

    /// A menu with `rows` under Copy, then `then`'s items.
    public init(rows: [Row], then: (@MainActor (NSMenu) -> Void)? = nil) {
        self.rows = rows
        self.then = then
    }

    /// Edits WebKit's default `menu` in place: the desktop items (Copy), then the rows.
    public func apply(to menu: NSMenu) {
        PageWKWebView.keepDesktopItems(in: menu)
        if !rows.isEmpty, menu.items.contains(where: { $0.identifier?.rawValue == PageSelectionMenu.copyItem }) {
            menu.addItem(.separator())
            for row in rows { menu.addItem(PageMenuAction.item(row.title, handler: row.run)) }
        }
        then?(menu)
    }

    /// Makes this menu `page`'s context menu.
    public func install(on page: PageWebView) {
        let menu = self
        page.contextMenuEditor = { menu.apply(to: $0) }
    }

    /// The localized titles of the viewer rows.
    public struct Titles {
        public init() {}
        /// "Comment…": opens the comment popover.
        public static var comment: String {
            String(localized: "pages.viewerSelection.comment", defaultValue: "Comment…", bundle: .module)
        }

        /// "Quote in Chat": sends the selection with no comment.
        public static var quoteInChat: String {
            String(localized: "pages.viewerSelection.quoteInChat", defaultValue: "Quote in Chat", bundle: .module)
        }

        /// The comment dialog's title, `Comment on README.md · L3–4`.
        public static func commentOn(_ title: String) -> String {
            String(localized: "pages.viewerSelection.commentOn", defaultValue: "Comment on \(title)", bundle: .module)
        }

        /// The comment field's placeholder.
        public static var commentPlaceholder: String {
            String(localized: "pages.viewerSelection.commentPlaceholder", defaultValue: "Your comment", bundle: .module)
        }

        /// The comment dialog's default button.
        public static var addToChat: String {
            String(localized: "pages.viewerSelection.addToChat", defaultValue: "Add to Chat", bundle: .module)
        }
    }
}
