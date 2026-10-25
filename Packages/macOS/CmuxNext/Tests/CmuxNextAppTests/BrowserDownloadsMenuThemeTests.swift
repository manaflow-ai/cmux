import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// A row's right-click menu in the toolbar's Downloads popup is a standard macOS menu, as every
/// right-click menu is (Lawrence 2026-10-23): every row is a plain AppKit row with its command's
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
            #expect(item.view == nil, "\(item.title) is custom-drawn, not a standard macOS row")
            #expect(item.image != nil, "\(item.title) has no icon")
        }

        // A chosen row runs, as a click does (`performActionForItem` needs a running
        // NSApplication; the fleet's test hosts have no general pasteboard, so Cancel shows it).
        let running = BrowserDownload(sourceURL: URL(string: "https://example.com/big.zip"), filename: "big.zip")
        list.add(running, tab: "tab-a") { _ in }
        let runningRow = BrowserDownloadRowEventView()
        runningRow.menuProvider = { BrowserDownloadsMenu.actions(running, list: list) }
        let cancel = try #require(runningRow.themedMenu()?.items.first { $0.title == BrowserHitStrings.downloadCancel })
        #expect(cancel.view == nil)
        _ = try #require(cancel.target as? NSObject).perform(try #require(cancel.action), with: cancel)
        #expect(running.status == .cancelled)
    }
}
