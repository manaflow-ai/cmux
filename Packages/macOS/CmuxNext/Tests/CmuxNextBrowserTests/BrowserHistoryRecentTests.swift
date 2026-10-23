@testable import CmuxNextBrowser
import Foundation
import Testing

/// A New Tab page, built on the key's turn of Cmd-T and Cmd-N, lists the 40 newest pages of a
/// history an import can make tens of thousands long. `recent(_:)` gives the head of `entries`
/// (newest first) without sorting every visit (perf-lead issue 11).
@MainActor
struct BrowserHistoryRecentTests {
    /// `count` pages visited one second apart, inserted in a scrambled order (7919 is prime, so
    /// `i * 7919 % count` visits every page once), so neither insertion order nor the history's
    /// own key order is newest first.
    private static func history(_ count: Int) throws -> InMemoryBrowserHistory {
        let entries = try (0..<count).map { index -> BrowserHistoryEntry in
            let page = index * 7919 % count
            return BrowserHistoryEntry(url: try #require(URL(string: "https://site\(page).example/")), title: "page \(page)",
                                       visitCount: 1, lastVisit: Date(timeIntervalSince1970: TimeInterval(page)))
        }
        return InMemoryBrowserHistory(entries: entries)
    }

    @Test(arguments: [0, 1, 39, 40, 41, 5_000])
    func theNewestPagesComeFirstAsTheWholeListHasThem(count: Int) throws {
        let history = try Self.history(count)
        #expect(history.recent(40) == Array(history.entries.prefix(40)))
    }

    @Test func aLimitOfNoneGivesNoPages() throws {
        #expect(try Self.history(10).recent(0).isEmpty)
    }
}
