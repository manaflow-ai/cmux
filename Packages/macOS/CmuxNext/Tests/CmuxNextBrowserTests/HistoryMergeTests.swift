import Foundation
import Testing
@testable import CmuxNextBrowser

/// Imported history joins the omnibar history without counting new visits.
@MainActor
@Suite struct HistoryMergeTests {
    let old = Date(timeIntervalSince1970: 1_000)
    let new = Date(timeIntervalSince1970: 2_000)

    @Test func mergeKeepsNewerVisitAndLargerCount() {
        let history = InMemoryBrowserHistory()
        history.recordVisit(url: URL(string: "https://a.example.com/")!, title: "Live", at: new)
        history.merge([
            BrowserHistoryEntry(url: URL(string: "https://a.example.com/")!, title: "Imported", visitCount: 9, lastVisit: old),
            BrowserHistoryEntry(url: URL(string: "https://b.example.com/")!, title: "B", visitCount: 2, lastVisit: old),
            BrowserHistoryEntry(url: URL(string: "chrome://settings")!, title: "No", visitCount: 1, lastVisit: new),
        ])
        let entries = history.entries
        #expect(entries.map(\.url.host) == ["a.example.com", "b.example.com"])
        #expect(entries[0].title == "Live" && entries[0].visitCount == 9 && entries[0].lastVisit == new)
        history.merge([BrowserHistoryEntry(url: URL(string: "https://b.example.com/")!, title: "B2", visitCount: 1, lastVisit: new)])
        #expect(history.entries.first { $0.url.host == "b.example.com" }?.title == "B2")
        #expect(history.entries.first { $0.url.host == "b.example.com" }?.visitCount == 2)
    }
}
