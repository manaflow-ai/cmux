public import Foundation

/// One URL of a browser profile's history as the omnibar's quick index
/// sees it (plans/cmux-next/omnibar-suggestions.md, "Quick history index"):
/// one row per URL, never per visit.
public nonisolated struct OmniboxHistoryRow: Hashable, Sendable {
    public var url: URL
    public var title: String?
    public var visitCount: Int
    /// Visits that started from text typed in the omnibar (Chromium
    /// `typed_count`).
    public var typedCount: Int
    public var lastVisit: Date

    public init(url: URL, title: String?, visitCount: Int, typedCount: Int = 0, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }
}

/// A change of a history source, in the order the source made it.
public nonisolated enum OmniboxHistoryChange: Hashable, Sendable {
    /// Every row: replaces what the index holds (a snapshot, a clear).
    case reset([OmniboxHistoryRow])
    /// Rows added or changed.
    case upsert([OmniboxHistoryRow])
    /// URLs forgotten (Shift-Delete, Clear History).
    case remove([URL])
}

/// Where the omnibar reads history. The omnibar never writes history truth:
/// it reads a snapshot, follows changes, and asks the owner to forget a URL.
///
/// Today the per-profile in-memory history (`InMemoryBrowserHistory`, made
/// durable by the App's visit log) is the source. When the daemon owns visits
/// (H3), a daemon-backed source replaces it: `snapshot()` is the visit store's
/// snapshot, `observe` follows its `history-changed` events and `delete` sends
/// `history.delete_url`. The suggestion pipeline does not change.
@MainActor public protocol OmniboxHistorySource: AnyObject {
    /// Every row now.
    func snapshot() async -> [OmniboxHistoryRow]
    /// Calls `handler` with every change after now, in order, until
    /// `stopObserving` with the returned token.
    func observe(_ handler: @escaping @MainActor (OmniboxHistoryChange) -> Void) -> Int
    func stopObserving(_ token: Int)
    /// Shift-Delete on a history row. The row leaves the index when the
    /// owner's `.remove` change comes back.
    func delete(_ url: URL)
    /// The next visit to `url` was typed in the omnibar (Chromium
    /// `PAGE_TRANSITION_TYPED`): it counts toward `typedCount`.
    func noteTyped(_ url: URL)
}
