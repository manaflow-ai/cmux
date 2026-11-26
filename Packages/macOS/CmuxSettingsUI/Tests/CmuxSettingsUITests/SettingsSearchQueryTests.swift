import CmuxSettings
import Foundation
import os
import Testing
@testable import CmuxSettingsUI

/// Typing into Settings search stalled a loaded MacBook Air: every keystroke
/// re-ran the fuzzy match over every indexed row on the main thread and
/// re-rendered the whole window, so keys were dropped. A burst of keystrokes
/// must now run one match, for the final query, off the main thread.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SettingsSearchQueryTests {
    /// Records each query the matcher ran and whether it ran on the main thread.
    final class MatchLog: Sendable {
        private let calls = OSAllocatedUnfairLock<[(query: String, onMain: Bool)]>(initialState: [])

        var queries: [String] { calls.withLock { $0.map(\.query) } }
        var ranOnMain: Bool { calls.withLock { $0.contains { $0.onMain } } }

        func record(_ query: String) {
            let onMain = Thread.isMainThread
            calls.withLock { $0.append((query, onMain)) }
        }

        func reset() {
            calls.withLock { $0.removeAll() }
        }
    }

    static let index = SettingsSearchIndex(catalog: SettingCatalog())

    static func makeQuery(log: MatchLog) -> SettingsSearchQuery {
        let index = index
        return SettingsSearchQuery(
            match: { query in
                log.record(query)
                return index.match(query)
            },
            debounce: .milliseconds(50)
        )
    }

    @Test func aBurstOfKeystrokesMatchesOnceOffTheMainThread() async {
        let log = MatchLog()
        let query = Self.makeQuery(log: log)
        log.reset()

        for prefix in ["t", "te", "ter", "term", "termi", "termin", "termina", "terminal"] {
            query.text = prefix
        }
        // The field shows every keystroke immediately; results wait.
        #expect(query.text == "terminal")
        #expect(!query.isShowingSearchResults)

        await query.settle()

        #expect(log.queries == ["terminal"])
        #expect(!log.ranOnMain)
        #expect(query.appliedText == "terminal")
        #expect(query.results == Self.index.match("terminal"))
        #expect(query.isShowingSearchResults)
    }

    @Test func clearingTheFieldRestoresSectionsAtOnceAndReportsIt() async {
        let log = MatchLog()
        let query = Self.makeQuery(log: log)
        @MainActor final class Counter { var value = 0 }
        let cleared = Counter()
        query.onQueryCleared = { cleared.value += 1 }

        query.text = "font"
        await query.settle()
        #expect(query.isShowingSearchResults)

        query.text = ""
        // No debounce for a blank query: the browse list is back synchronously.
        #expect(!query.isShowingSearchResults)
        #expect(query.results == Self.index.match(""))
        #expect(cleared.value == 1)
    }

    @Test func aStaleMatchNeverReplacesNewerResults() async {
        let log = MatchLog()
        let query = Self.makeQuery(log: log)

        query.text = "font"
        await query.settle()
        query.text = "scroll"
        query.text = "scroll speed"
        await query.settle()

        #expect(query.appliedText == "scroll speed")
        #expect(query.results == Self.index.match("scroll speed"))
    }
}
