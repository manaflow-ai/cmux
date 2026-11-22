import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation
import Observation

/// Bookmark rows in a browser profile's omnibar (star icon): every change of
/// the profile's bookmarks goes to its suggestion engine, whose phase A actor
/// indexes them with the history rules (plans/cmux-next/omnibar-suggestions.md).
/// A bookmarked page also in history shows once: the higher score wins.
@MainActor
enum BookmarkSuggestionFeed {
    static func follow(_ service: BookmarkService, profile: String, into engine: OmniboxSuggestionEngine) {
        // task-owner: lives as long as the engine and the service; both weak.
        Task { [weak service, weak engine] in
            guard let service else { return }
            for await nodes in Observations({ service.tree(profile).bookmarks }) {
                guard let engine else { return }
                engine.setBookmarks(rows(nodes))
            }
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
