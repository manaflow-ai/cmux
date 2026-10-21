import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// A row's right-click menu in the toolbar's Downloads popup takes the cmux NEXT menu look, as the
/// right-click menus do (#22787): every row is a cmux-drawn `ThemedMenuRowView` with its command's
/// icon, and a chosen row still runs.
@MainActor @Suite(.serialized) struct BrowserDownloadsMenuThemeTests {
    @Test func aDownloadRowsMenuIsThemedWithIconsAndItsRowsRun() throws {
        let list = BrowserDownloadList()
        let file = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString).pdf")
        list.add(.ended(sourceURL: URL(string: "https://example.com/report.pdf"), filename: "report.pdf", destination: file,
                        status: .finished, receivedBytes: 10, totalBytes: 10), tab: "tab-a") { _ in }
        let download = try #require(list.items.first)
        let row = BrowserDownloadRowEventView()
        row.menuProvider = { BrowserDownloadsMenu.actions(download, list: list) }
        let menu = try #require(row.themedMenu())

        #expect(menu.items.map(\.title).contains(BrowserHitStrings.downloadCopyLink))
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.view is ThemedMenuRowView, "\(item.title) is not themed")
            #expect(item.image != nil, "\(item.title) has no icon")
        }

        NSPasteboard.general.clearContents()
        let copy = try #require(menu.items.firstIndex { $0.title == BrowserHitStrings.downloadCopyLink })
        menu.performActionForItem(at: copy)
        #expect(NSPasteboard.general.string(forType: .string) == "https://example.com/report.pdf")
    }
}
