@testable import CmuxNextBrowser
import Foundation
import Testing

/// Shift-Delete through the history-source interface (R110 pair 3): the
/// engine asks the owner to forget the URL and keeps the row out of every
/// result as a pending intent until the owner's removal reaches the index,
/// so an owner that answers late (the daemon, H3) never shows it again.
@MainActor
@Suite struct OmniboxPendingDeleteTests {
    /// A history owner that answers deletes only when the test says so.
    final class LateSource: OmniboxHistorySource {
        var rows: [OmniboxHistoryRow]
        private(set) var deleted: [URL] = []
        private var handlers: [Int: @MainActor (OmniboxHistoryChange) -> Void] = [:]

        init(_ rows: [OmniboxHistoryRow]) { self.rows = rows }

        func snapshot() async -> [OmniboxHistoryRow] { rows }
        func observe(_ handler: @escaping @MainActor (OmniboxHistoryChange) -> Void) -> Int {
            handlers[handlers.count + 1] = handler
            return handlers.count
        }
        func stopObserving(_ token: Int) { handlers[token] = nil }
        func delete(_ url: URL) { deleted.append(url) }
        func noteTyped(_ url: URL) {}

        func echoRemoval(of url: URL) {
            rows.removeAll { $0.url == url }
            for handler in handlers.values { handler(.remove([url])) }
        }
    }

    @Test func aDeletedRowStaysHiddenUntilTheOwnerEchoesIt() async {
        let github = URL(string: "https://github.com/")!
        let source = LateSource([OmniboxFixtures.row("https://github.com/", "GitHub", visits: 9),
                                 OmniboxFixtures.row("https://gitlab.com/", "GitLab", visits: 9)])
        let engine = OmniboxSuggestionEngine(history: source)
        engine.now = { OmniboxFixtures.now }
        await engine.historySettled()
        #expect(await engine.suggestions(for: "git").contains { $0.url == github })

        engine.deleteSuggestion(github)
        #expect(source.deleted == [github])
        let pending = await engine.suggestions(for: "git")
        #expect(!pending.contains { $0.url == github }, "hidden as a pending intent")
        #expect(pending.contains { $0.url.host() == "gitlab.com" })
        #expect(await engine.local.historyContains(github), "the index waits for the owner")

        source.echoRemoval(of: github)
        await engine.historySettled()
        #expect(!(await engine.local.historyContains(github)))
        #expect(engine.pendingDeletes.isEmpty)
        #expect(!(await engine.suggestions(for: "git")).contains { $0.url == github })
    }
}
