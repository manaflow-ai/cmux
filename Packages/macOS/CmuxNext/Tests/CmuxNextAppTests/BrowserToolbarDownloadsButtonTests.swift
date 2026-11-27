@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// The toolbar's Downloads button shows on a tab only once that tab downloaded something in this
/// run, or while any download runs (Lawrence 2026-10-18: it showed on a Chrome Web Store page that
/// downloaded nothing, "showing up in the wrong place, kind of arbitrarily"). Before, any row in
/// the app-wide list, kept ones from an earlier run included, showed it on every tab.
@MainActor @Suite struct BrowserToolbarDownloadsButtonTests {
    private func shows(_ downloads: BrowserToolbarDownloads) -> Bool {
        BrowserToolbarButton.downloads.isShown(at: 0, BrowserToolbarFacts(engine: .cef, hostsDevTools: true, downloads: downloads),
                                               pinned: [.downloads])
    }

    @Test func aDownloadKeptFromAnEarlierRunShowsNoButton() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "toolbar-downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "downloads.json")
        try Data(#"{"downloads":[{"filename":"old.zip","status":"finished","received":10}]}"#.utf8).write(to: file)
        let list = BrowserDownloadList()
        list.history = BrowserDownloadHistory(url: file)
        await list.restore()
        #expect(list.items.count == 1)
        #expect(list.toolbarSummary(forTab: "tab-a").count == 0)
        #expect(!shows(list.toolbarSummary(forTab: "tab-a")))
    }

    @Test func onlyTheTabThatDownloadedShowsTheButtonOnceItEnds() {
        let list = BrowserDownloadList()
        let item = BrowserDownload.ended(sourceURL: URL(string: "https://example.com/a.zip"), filename: "a.zip", destination: nil,
                                         status: .finished, receivedBytes: 1, totalBytes: 1)
        list.add(item, tab: "tab-a") { _ in }
        #expect(shows(list.toolbarSummary(forTab: "tab-a")))
        #expect(!shows(list.toolbarSummary(forTab: "tab-b")))
        list.clearEnded()
        #expect(!shows(list.toolbarSummary(forTab: "tab-a")))
    }

    @Test func aRunningDownloadShowsTheButtonOnEveryTab() {
        let list = BrowserDownloadList()
        list.add(BrowserDownload(sourceURL: URL(string: "https://example.com/b.zip"), filename: "b.zip"), tab: "tab-a") { _ in }
        let other = list.toolbarSummary(forTab: "tab-b")
        #expect(other.count == 0)
        #expect(other.inProgress)
        #expect(shows(other))
    }
}
