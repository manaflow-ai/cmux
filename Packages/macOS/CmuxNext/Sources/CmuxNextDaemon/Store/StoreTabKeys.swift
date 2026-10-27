import Foundation

/// The tab keys one store lists (durable tab ids and tab resource ids: the keys of
/// ``DaemonStore/tab(idOrResource:)``), counted per indexed tab record, and the listeners told which
/// keys became listed or stopped being listed (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// 051). An index over several stores (`MachineTabIndex`, CmuxNextDaemonService) keeps itself by
/// these changes, never by a walk of the stores. ``StoreIndex`` reports each tab record it keys or
/// drops, so a change costs the records it names.
///
/// Changes are reported as net changes when the store publishes its tab list
/// (`DaemonStore.publishTabListChange`, once per apply and per intent shown, with
/// ``DaemonStore/tabListRevision``): the index re-keys a record by dropping and keying it again, and
/// an apply lifts the intent overlay and restores it, so each key keeps the count it had at the last
/// publish, and ``publish()`` reports only the keys whose presence differs. A move inside the store,
/// a re-index, a lift and restore and a rebuild of the same tree report nothing. Chromium reports a
/// tab's attach and detach the same way, once per move, not per step
/// (`TabStripModelObserver::OnTabStripModelChanged`, chrome/browser/ui/tabs/tab_strip_model_observer.h).
@MainActor public final class StoreTabKeys {
    /// What happened to a key since the last publish.
    public enum Change: Sendable, Equatable {
        /// The key was not listed at the last publish and is now.
        case listed
        /// The key was listed at the last publish and is not now.
        case dropped
    }

    /// Indexed tab records per key: two while a move's added delta carries its own record of a tab.
    private var counts: [String: Int] = [:]
    /// Each key changed since the last publish, with its count at that publish.
    private var published: [String: Int] = [:]
    /// Told of each publish's net changes, by the object that listens.
    private var listeners: [ObjectIdentifier: @MainActor ([String: Change]) -> Void] = [:]

    public init() {}

    /// Every key the store lists now.
    public var listed: Dictionary<String, Int>.Keys { counts.keys }

    /// Whether a tab record with durable id or tab resource id `key` is indexed.
    public func lists(_ key: String) -> Bool { counts[key] != nil }

    /// Tells `onChange` the net changes of each publish, until ``stopListening(_:)`` with the same
    /// `listener`; a second call for the same listener replaces its closure.
    public func listen(_ listener: AnyObject, _ onChange: @escaping @MainActor ([String: Change]) -> Void) {
        listeners[ObjectIdentifier(listener)] = onChange
    }

    /// Stops telling `listener`; other listeners keep theirs.
    public func stopListening(_ listener: AnyObject) {
        listeners[ObjectIdentifier(listener)] = nil
    }

    /// The store published its tab list: tells the listeners each key whose presence changed since
    /// the last publish. Costs the keys changed since then.
    func publish() {
        guard !published.isEmpty else { return }
        var changes: [String: Change] = [:]
        for (key, count) in published where (count == 0) != (counts[key] == nil) {
            changes[key] = count == 0 ? .listed : .dropped
        }
        published.removeAll(keepingCapacity: true)
        guard !changes.isEmpty else { return }
        for onChange in listeners.values { onChange(changes) }
    }

    // MARK: StoreIndex hooks

    /// A tab record was keyed under `id` and `resource`.
    func noteKeyed(id: String, resource: ResourceID?) {
        count(id, by: 1)
        if let resource { count(resource.rawValue, by: 1) }
    }

    /// A tab record keyed under `id` and `resource` was dropped.
    func noteUnkeyed(id: String, resource: ResourceID?) {
        count(id, by: -1)
        if let resource { count(resource.rawValue, by: -1) }
    }

    /// The index starts over from no records (``StoreIndex/rebuild(_:)``): each key keeps its count
    /// from the last publish, so the next publish reports only the keys the rebuild changed.
    func noteRebuildStarted() {
        for (key, count) in counts where published[key] == nil { published[key] = count }
        counts.removeAll(keepingCapacity: true)
    }

    private func count(_ key: String, by step: Int) {
        let current = counts[key] ?? 0
        if published[key] == nil { published[key] = current }
        let after = max(current + step, 0)
        counts[key] = after > 0 ? after : nil
    }
}
