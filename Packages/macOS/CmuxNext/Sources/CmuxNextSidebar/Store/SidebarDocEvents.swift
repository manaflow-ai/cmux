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

/// One observer of a `SidebarDocStore`, as Chromium's `base::CallbackListSubscription` (base/callback_list.h): its
/// events stop on `cancel()` or when it is released, whichever comes first. The store holds it weakly.
@MainActor
public final class SidebarDocObservation {
    private weak var store: SidebarDocStore?
    fileprivate private(set) var handler: (@MainActor (SidebarDocEvent) -> Void)?

    fileprivate init(store: SidebarDocStore, handler: @escaping @MainActor (SidebarDocEvent) -> Void) {
        self.store = store
        self.handler = handler
    }

    /// The store this observes; nil once cancelled or once the store is gone.
    public var observed: SidebarDocStore? { store }

    public func cancel() {
        handler = nil
        store = nil
    }
}

/// A store's observers in the order they were added, as `base::ObserverList` (base/observer_list.h) keeps them.
@MainActor
final class SidebarDocObservers {
    @MainActor private struct Entry {
        weak var observation: SidebarDocObservation?
        var isLive: Bool { observation?.handler != nil }
    }

    private var entries: [Entry] = []

    func add(_ handler: @escaping @MainActor (SidebarDocEvent) -> Void, of store: SidebarDocStore) -> SidebarDocObservation {
        entries.removeAll { !$0.isLive }
        let observation = SidebarDocObservation(store: store, handler: handler)
        entries.append(Entry(observation: observation))
        return observation
    }

    /// Tells each observer `event` in the order they were added. One cancelled or released by an earlier handler is
    /// skipped; one added meanwhile hears the next event (`ObserverListPolicy::EXISTING_ONLY`).
    func tell(_ event: SidebarDocEvent) {
        for entry in entries { entry.observation?.handler?(event) }
        entries.removeAll { !$0.isLive }
    }
}
