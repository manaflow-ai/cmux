/// The pages a hover restored from hibernation, oldest first (plans/cmux-next/hover-preload-DESIGN.md).
/// Pure: `BrowserHibernation` reports each restore, load end, show, close and discard. At most
/// `HoverWakeBudget.inFlight` live at once: a newer intent retires the oldest (Chrome's hover
/// prerenders, first in first out). A restore counts as in flight until its load ends.
package nonisolated struct HoverRestores: Equatable, Sendable {
    /// Oldest first.
    package private(set) var pages: [String] = []
    package private(set) var loading: Set<String> = []

    package init() {}

    package func contains(_ key: String) -> Bool { pages.contains(key) }

    package mutating func restored(_ key: String) {
        guard !pages.contains(key) else { return }
        pages.append(key)
        loading.insert(key)
    }

    package mutating func loaded(_ key: String) { loading.remove(key) }

    /// No longer a hover restore to send back (shown, closed, discarded, or kept by its own page).
    package mutating func drop(_ key: String) {
        pages.removeAll { $0 == key }
        loading.remove(key)
    }

    /// The oldest pages not in `keeping` beyond `room`, to discard now; they stop counting as in flight.
    package mutating func retire(keeping: Set<String>, room: Int) -> [String] {
        let older = pages.filter { !keeping.contains($0) }
        let retired = Array(older.prefix(max(0, older.count - max(0, room))))
        loading.subtract(retired)
        return retired
    }

    /// Restores still loading, not counting `keys`.
    package func loading(excluding keys: some Sequence<String>) -> Int { loading.subtracting(keys).count }
}
