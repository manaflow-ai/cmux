public import Foundation
import CmuxNextBrowserCore
import CmuxNextCompat

/// Keeps each omnibar suggestion engine's open-tab index (Switch to Tab rows) as the cache's pages open, navigate,
/// change title and close, so a typed key only queries the index and walks no page (HOT PATH AUDIT browser,
/// AUDIT row 6; Chrome's open-tab provider follows tab events the same way). The App calls `follow` when a page is
/// installed and `stop` when it leaves. Before, every key rebuilt and sorted the whole open-tab list on the main thread.
public final class OmniboxOpenTabFeed {
    /// What a Switch to Tab row of a page shows (an Equatable value: the follow wakes only when it changed).
    nonisolated struct Facts: Equatable, Sendable {
        var url: URL?
        var title: String?
    }

    public init() {}

    private var follows: [String: Task<Void, Never>] = [:]
    /// The engine each tab's row is in, and the row it holds there.
    private var placed: [String: (engine: OmniboxSuggestionEngine, row: OmniboxTabRow)] = [:]

    /// Follows `page`, tab `key`, into the engine `engineFor` names for it (its profile's, or incognito's).
    public func follow(_ page: any BrowserTab, key: String, engineFor: @escaping @MainActor (any BrowserTab) -> OmniboxSuggestionEngine?) {
        follows.removeValue(forKey: key)?.cancel()
        follows[key] = Task { [weak self, weak page] in
            for await facts in ObservationStream({ [weak page] in page.map { let state = $0.state; return Facts(url: state.url, title: state.title) } }) {
                guard let self, let page, let facts else { return }
                self.place(key, facts: facts, engine: engineFor(page))
            }
        }
    }

    /// Tab `key` left the cache: its row leaves its engine.
    public func stop(_ key: String) {
        follows.removeValue(forKey: key)?.cancel()
        placed.removeValue(forKey: key)?.engine.removeOpenTab(key)
    }

    private func place(_ key: String, facts: Facts, engine: OmniboxSuggestionEngine?) {
        let row = facts.url.flatMap { url in BrowserNewTabPage.isNewTabPage(url) ? nil : OmniboxTabRow(key: key, url: url, title: facts.title) }
        if let old = placed[key], row == nil || old.engine !== engine {
            old.engine.removeOpenTab(key)
            placed[key] = nil
        }
        guard let row, let engine, placed[key]?.row != row else { return }
        engine.setOpenTab(row)
        placed[key] = (engine, row)
    }
}
