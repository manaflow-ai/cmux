import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Observation

/// Bookmark rows in a browser profile's omnibar (star icon): every change of
/// the profile's bookmarks goes to its suggestion engine, whose phase A actor
/// indexes them with the history rules (plans/cmux-next/omnibar-suggestions.md).
/// A bookmarked page also in history shows once: the higher score wins.
@MainActor
enum BookmarkSuggestionFeed {
    /// The service keeps each engine's feed; the feed ends at the first change after its engine is gone.
    /// `background`: the omnibar's index takes the rows in its own time; a person's own edit flushes as
    /// userBlocking by its cause.
    static func follow(_ service: BookmarkService, profile: String, into engine: OmniboxSuggestionEngine) {
        let key = ObjectIdentifier(engine)
        service.suggestionFeeds[key] = ServiceObservation(.background, owner: "BookmarkSuggestionFeed", on: service.services.mainWork) { [weak service] in
            service?.tree(profile).bookmarks ?? []
        } apply: { [weak service, weak engine] nodes in
            guard let engine else {
                service?.suggestionFeeds[key] = nil
                return
            }
            engine.setBookmarks(rows(nodes))
        }
    }

    /// Pure: bookmark nodes as index rows (last use, else creation, is the
    /// visit time).
    nonisolated static func rows(_ nodes: [BookmarkNode]) -> [OmniboxHistoryRow] {
        nodes.compactMap { node in
            guard let url = node.url else { return nil }
            return OmniboxHistoryRow(url: url, title: node.title.isEmpty ? nil : node.title, visitCount: 1, typedCount: 1,
                                     lastVisit: node.lastUsed ?? node.created)
        }
    }
}
