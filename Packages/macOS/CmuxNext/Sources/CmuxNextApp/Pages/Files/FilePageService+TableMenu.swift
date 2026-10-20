import AppKit
import CmuxNextPages

/// The markdown page's table rows: Reset Column Widths, added after the selection rows when the
/// right-click was on a table (the page reports it through `cmux.markdown.contextTable` before the
/// menu opens; MARKDOWN-TABLE-WIDTHS-DESIGN.md). ``ViewerSelectionMenu`` has already reduced the menu
/// to the desktop default.
extension FilePageService {
    static func tableMenu(provider: FilePageProvider, page: PageWebView) -> @MainActor (NSMenu) -> Void {
        { [weak provider, weak page] menu in
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
