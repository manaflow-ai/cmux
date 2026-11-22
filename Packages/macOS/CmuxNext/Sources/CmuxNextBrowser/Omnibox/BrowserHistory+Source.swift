public import Foundation

/// The per-profile in-memory history is the omnibar's history source until
/// the daemon owns visits (H3). Its changes reach observers synchronously,
/// so a Shift-Delete echo arrives before the next keystroke. Incognito
/// histories are the same type with no persistence: their index stays in
/// memory and nothing reaches the daemon or disk.
extension InMemoryBrowserHistory: OmniboxHistorySource {
    public func snapshot() async -> [OmniboxHistoryRow] {
        entries.map(\.omniboxRow)
    }

    public func observe(_ handler: @escaping @MainActor (OmniboxHistoryChange) -> Void) -> Int {
        let token = nextObserver
        nextObserver += 1
        observers[token] = handler
        return token
    }

    public func stopObserving(_ token: Int) {
        observers[token] = nil
    }

    public func delete(_ url: URL) {
        removeEntry(for: url)
    }

    public func noteTyped(_ url: URL) {
        guard Self.isRecordable(url) else { return }
        pendingTyped.insert(BrowserHistoryRanker.dedupeKey(for: url))
    }

    func notify(_ change: OmniboxHistoryChange) {
        for handler in observers.values { handler(change) }
    }
}
