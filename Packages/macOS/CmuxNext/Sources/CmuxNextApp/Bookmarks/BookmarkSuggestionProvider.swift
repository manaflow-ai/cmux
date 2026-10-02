import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation

/// Bookmark rows in a browser profile's omnibar (star icon), ranked by
/// `BookmarkRanker` (Chromium's BookmarkProvider rule). A bookmarked page also
/// in history wins the row: the engine keeps the higher score per page.
@MainActor
final class BookmarkSuggestionProvider: BrowserSuggestionProvider {
    private weak var service: BookmarkService?
    private let profile: String
    private let limit: Int

    init(service: BookmarkService, profile: String, limit: Int = 4) {
        self.service = service
        self.profile = profile
        self.limit = limit
    }

    func suggestions(for text: String) async -> [BrowserSuggestion] {
        guard let service else { return [] }
        let nodes = service.tree(profile).bookmarks
        return BookmarkRanker.matches(in: nodes, for: text, now: Date(), limit: limit).compactMap { match in
            guard let url = match.node.url else { return nil }
            let display = BrowserURLDisplay.displayText(for: url)
            return BrowserSuggestion(kind: .bookmark, title: match.node.title.isEmpty ? display : match.node.title, detail: display,
                                     url: url, score: match.score)
        }
    }
}
