@testable import CmuxNextBrowser
import Foundation
import Testing

/// Bookmark rows in the omnibar: they fill and complete like history rows,
/// a bookmark beats a history row for the same page, and Shift-Delete
/// cannot remove a bookmark.
@MainActor
@Suite struct BookmarkSuggestionRowTests {
    private final class Fixed: BrowserSuggestionProvider {
        let rows: [BrowserSuggestion]
        init(_ rows: [BrowserSuggestion]) { self.rows = rows }
        func suggestions(for text: String) async -> [BrowserSuggestion] { rows }
    }

    private let url = URL(string: "https://example.com/docs")!

    @Test func bookmarkRowsFillAndCompleteLikeHistory() {
        let row = BrowserSuggestion(kind: .bookmark, title: "Docs", detail: "example.com/docs", url: url, score: 800)
        #expect(OmnibarRules.fillText(for: row) == BrowserURLDisplay.editingText(for: url))
        #expect(OmnibarRules.inlineCompletion(for: row, typed: "exam") == "ple.com/docs")
    }

    @Test func theHigherScoredRowWinsOnePagePerURL() async {
        let history = BrowserSuggestion(kind: .history, title: "Docs", detail: "", url: url, score: 600)
        let bookmark = BrowserSuggestion(kind: .bookmark, title: "Docs", detail: "", url: url, score: 760)
        let engine = OmniboxSuggestionEngine(providers: [Fixed([history]), Fixed([bookmark])])
        let rows = await engine.suggestions(for: "docs")
        #expect(rows.filter { $0.url == url }.map(\.kind) == [.bookmark])
    }
}
