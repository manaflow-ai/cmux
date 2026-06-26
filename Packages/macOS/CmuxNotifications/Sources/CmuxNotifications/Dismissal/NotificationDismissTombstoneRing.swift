public import Foundation

/// Bounded, write-through ring of recently dismissed/cleared notification ids.
///
/// Kept so the phone's foreground reconcile sweep can classify a delivered
/// banner as "handled here" even after the entry left the store entirely
/// (remove / clear-all paths). Oldest ids are evicted past ``defaultCapacity``.
/// Holds opaque `UUID`s only, never content.
///
/// Write-through persisted to the injected `UserDefaults` (lazy-loaded on first
/// use) so the reconcile lane survives a Mac relaunch: session restore keeps
/// notification ids stable, so a phone that reconnects after the app restarted
/// must still learn that a banner it holds was dismissed here even when the
/// silent dismiss push never reached it.
///
/// A value type whose mutators are `mutating`: the owning `@MainActor` store
/// holds a single instance, so persistence and eviction stay co-located with
/// the store's other notification state. `UserDefaults` is injected (defaulting
/// to `.standard`) so tests can scope a suite.
public struct NotificationDismissTombstoneRing {
    /// The `UserDefaults` key the persisted id array is written to and read from.
    public static let defaultPersistenceKey = "cmux.notifications.dismissedTombstoneIds"
    /// The maximum number of retained tombstone ids before the oldest are evicted.
    public static let defaultCapacity = 512

    private let defaults: UserDefaults
    private let persistenceKey: String
    private let capacity: Int
    private var tombstoneIDs = Set<UUID>()
    private var insertionOrder: [UUID] = []
    private var isLoaded = false

    /// Creates a ring backed by the given defaults store, key, and capacity.
    public init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = NotificationDismissTombstoneRing.defaultPersistenceKey,
        capacity: Int = NotificationDismissTombstoneRing.defaultCapacity
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.capacity = capacity
    }

    /// Lazily reads the persisted id array on first use, merging it into the
    /// in-memory set/order without disturbing already-present ids.
    public mutating func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let stored = defaults.stringArray(forKey: persistenceKey) ?? []
        for id in stored.compactMap({ UUID(uuidString: $0) }) where tombstoneIDs.insert(id).inserted {
            insertionOrder.append(id)
        }
    }

    /// Records the given ids as tombstones, evicting the oldest past capacity and
    /// write-through persisting the resulting order.
    public mutating func record(ids: [UUID]) {
        loadIfNeeded()
        for id in ids where tombstoneIDs.insert(id).inserted {
            insertionOrder.append(id)
        }
        let overflow = insertionOrder.count - capacity
        if overflow > 0 {
            for stale in insertionOrder.prefix(overflow) {
                tombstoneIDs.remove(stale)
            }
            insertionOrder.removeFirst(overflow)
        }
        defaults.set(
            insertionOrder.map(\.uuidString),
            forKey: persistenceKey
        )
    }

    /// Whether the given id is currently tombstoned.
    public func contains(_ id: UUID) -> Bool {
        tombstoneIDs.contains(id)
    }

    /// Drops the in-memory copy so the next use re-reads the persisted ring —
    /// the behavior-test analogue of a process restart.
    public mutating func reloadForTesting() {
        tombstoneIDs.removeAll()
        insertionOrder.removeAll()
        isLoaded = false
    }
}
