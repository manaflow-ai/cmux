/// What a `SidebarDocStore` tells its observers (`SidebarDocStore.observe(_:)`). The store tells each observer
/// directly, as a Chromium model tells its `base::ObserverList` (base/observer_list.h), instead of an app-wide
/// broadcast.
public nonisolated enum SidebarDocEvent: Hashable, Sendable {
    /// The change `key` was refused (by the mirror or the daemon): a list holding that drop's look lets it go.
    case refused(key: String)
    /// The change `key` changed nothing (a no-op move echoes no batch): a list holding its look lets it go.
    case settled(key: String)
    /// The favicons link rows draw changed: every list draws its link rows again.
    case faviconsChanged
}

/// One observer of a `SidebarDocStore`; `cancel()` stops its events (the store keeps the handler until then).
@MainActor
public final class SidebarDocObservation {
    private weak var store: SidebarDocStore?
    private weak var observers: SidebarDocObservers?
    private let id: UInt64

    fileprivate init(store: SidebarDocStore, observers: SidebarDocObservers, id: UInt64) {
        self.store = store
        self.observers = observers
        self.id = id
    }

    /// The store this observes; nil once cancelled or once the store is gone.
    public var observed: SidebarDocStore? { store }

    public func cancel() {
        observers?.remove(id)
        observers = nil
        store = nil
    }
}

/// A store's observers by id (`SidebarDocStore.observe(_:)`), told in no particular order.
@MainActor
final class SidebarDocObservers {
    private var handlers: [UInt64: @MainActor (SidebarDocEvent) -> Void] = [:]
    private var nextID: UInt64 = 0

    func add(_ handler: @escaping @MainActor (SidebarDocEvent) -> Void, of store: SidebarDocStore) -> SidebarDocObservation {
        nextID &+= 1
        handlers[nextID] = handler
        return SidebarDocObservation(store: store, observers: self, id: nextID)
    }

    fileprivate func remove(_ id: UInt64) { handlers[id] = nil }

    /// Tells every observer `event`; one that cancels or adds an observer meanwhile changes only the next event's list.
    func tell(_ event: SidebarDocEvent) {
        for handler in Array(handlers.values) { handler(event) }
    }
}
