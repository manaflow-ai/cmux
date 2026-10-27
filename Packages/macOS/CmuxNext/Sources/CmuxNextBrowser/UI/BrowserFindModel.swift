public import Observation

/// One browser chrome's find in page: whether the bar shows, what it searches for and the engine's last answer.
/// Chromium keeps the same per tab in `FindTabHelper` (`find_text_`, `find_result_`'s `number_of_matches` and
/// `active_match_ordinal`; components/find_in_page/find_tab_helper.h); the find bar view writes it and renders
/// from it, and readers (the oracle's `overlays` facet) read it instead of the view.
@MainActor
@Observable
public final class BrowserFindModel {
    /// True while the find bar shows.
    public internal(set) var isPresented = false
    /// The text searched for. Kept after the bar closes.
    public internal(set) var query = ""
    /// Matches on the page; nil until the engine reports a count.
    public internal(set) var matchCount: Int?
    /// The active match's 0-based index; nil when none is active.
    public internal(set) var activeIndex: Int?

    public init() {}

    /// The engine answered a search for `text` (the query when it was sent).
    func record(_ result: BrowserFindResult, for text: String) {
        guard text == query else { return }
        matchCount = text.isEmpty ? nil : result.matchFound ? result.matchCount : 0
        activeIndex = text.isEmpty || !result.matchFound ? nil : result.currentIndex.map { max($0 - 1, 0) }
    }

    /// The query changed: the last answer was for another text.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        matchCount = nil
        activeIndex = nil
    }
}
