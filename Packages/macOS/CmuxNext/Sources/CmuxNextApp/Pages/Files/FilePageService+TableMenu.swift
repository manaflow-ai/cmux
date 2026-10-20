import AppKit
import CmuxNextPages

/// The markdown page's right-click menu: WebKit's desktop default (Copy on a selection), plus Reset
/// Column Widths when the right-click was on a table (the page reports it through
/// `cmux.markdown.contextTable` before the menu opens; MARKDOWN-TABLE-WIDTHS-DESIGN.md).
extension FilePageService {
    static func tableMenu(provider: FilePageProvider, page: PageWebView) -> @MainActor (NSMenu) -> Void {
        { [weak provider, weak page] menu in
            PageWebView.keepDefaultMenuItems(in: menu)
            guard provider?.contextTable != nil else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(PageWebView.menuItem(resetColumnWidthsTitle) {
                _ = page?.send(command: MarkdownPageCommand.resetContextTableWidths)
            })
        }
    }

    static var resetColumnWidthsTitle: String {
        String(localized: "filePages.markdown.resetColumnWidths", defaultValue: "Reset Column Widths", table: "FilePages", bundle: .module)
    }
}
