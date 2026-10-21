import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// The toolbar's Downloads menu takes the cmux NEXT menu look (the toolbar presents it themed, as
/// the right-click menus are, #22787): every row is a cmux-drawn `ThemedMenuRowView` with an icon
/// (the file type's for a download, its command's otherwise), its submenus too, and a chosen row
/// still runs.
@MainActor @Suite(.serialized) struct BrowserDownloadsMenuThemeTests {
    private func expectThemedWithIcons(_ menu: NSMenu, _ name: String) {
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.view is ThemedMenuRowView, "\(name): \(item.title) is not themed")
            #expect(item.image != nil, "\(name): \(item.title) has no icon")
            if let submenu = item.submenu { expectThemedWithIcons(submenu, "\(name) ▸ \(item.title)") }
        }
    }

    private func presented(_ list: BrowserDownloadList) -> NSMenu {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let menu = BrowserDownloadsMenu.menu(list, target: ActionTargetRef(kind: .tab, id: "tab-a"), registry: registry)
        let buttons = BrowserToolbarButtonsView()
        buttons.popUpMenu = { _, _, _ in }
        buttons.present(menu, from: .downloads, themed: true)
        return menu
    }

    @Test func everyRowIsThemedWithAnIconAndClearRuns() throws {
        let list = BrowserDownloadList()
        let file = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString).pdf")
        list.add(.ended(sourceURL: URL(string: "https://example.com/report.pdf"), filename: "report.pdf", destination: file,
                        status: .finished, receivedBytes: 10, totalBytes: 10), tab: "tab-a") { _ in }
        let menu = presented(list)
        expectThemedWithIcons(menu, "Downloads")
        let row = try #require(menu.items.first { $0.title == "report.pdf" })
        #expect(row.image?.isTemplate == false, "a download shows its file type's icon")
        #expect(row.submenu?.items.map(\.title).contains(BrowserHitStrings.downloadCopyLink) == true)

        let clear = try #require(menu.items.firstIndex { $0.title == BrowserHitStrings.downloadsClear })
        menu.performActionForItem(at: clear)
        #expect(list.items.isEmpty)
    }

    @Test func theEmptyMenuIsThemedToo() {
        expectThemedWithIcons(presented(BrowserDownloadList()), "Downloads (empty)")
    }
}
