public import AppKit

/// Extra rows on a page's Copy-only default menu while text is selected (u5402: "Send to Chief"
/// and "Send to…" on a Markdown page). Rows show only when WebKit offers Copy (a selection).
@MainActor
public struct PageSelectionRows {
    /// Each row's title and what it runs with the selected text.
    public var rows: [(title: String, run: (String) -> Void)]

    public init(rows: [(title: String, run: (String) -> Void)]) {
        self.rows = rows
    }

    /// `page`'s menu editor: the desktop default (Copy), then a separator and the rows.
    public func install(on page: PageWebView) {
        let rows = rows
        page.contextMenuEditor = { [weak page] menu in
            PageWKWebView.keepDesktopItems(in: menu)
            guard let page, menu.items.contains(where: { $0.identifier?.rawValue == PageSelectionMenu.copyItem }) else { return }
            menu.addItem(.separator())
            for row in rows {
                menu.addItem(PageMenuAction.item(row.title) { [weak page] in
                    page?.webKitView.evaluateJavaScript("String(getSelection())") { value, _ in
                        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        row.run(text)
                    }
                })
            }
        }
    }
}
