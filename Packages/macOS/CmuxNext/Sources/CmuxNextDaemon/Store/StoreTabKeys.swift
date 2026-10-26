import Foundation

/// The tab keys one store lists (durable tab ids and tab resource ids: the keys of
/// ``DaemonStore/tab(idOrResource:)``), counted per indexed tab record, and the one listener told
/// when a key is first listed or last dropped (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// 051). An index over several stores (`MachineTabIndex`, CmuxNextDaemonService) keeps itself by
/// these changes, never by a walk of the stores. ``StoreIndex`` reports each tab record it keys or
/// drops, so a change costs the records it names.
///
/// A rebuild (a full snapshot) indexes every record again without dropping them one by one: the
/// keys are compared once at its end, and the listener hears only the keys it added or removed.
@MainActor public final class StoreTabKeys {
    /// What happened to a key.
    public enum Change: Sendable, Equatable {
        /// The first tab record with this key was indexed.
        case listed
        /// The last tab record with this key was dropped.
        case dropped
    }

    /// Told of each key that became listed or stopped being listed. One index over this store sets it.
    public var onChange: (@MainActor (String, Change) -> Void)?

    /// Indexed tab records per key: two while a move's added delta carries its own record of a tab.
    private var counts: [String: Int] = [:]
    /// The counts before the rebuild in progress; nil outside one.
    private var beforeRebuild: [String: Int]?

    public init() {}

    /// Every key the store lists now.
    public var listed: Dictionary<String, Int>.Keys { counts.keys }

    /// Whether a tab record with durable id or tab resource id `key` is indexed.
    public func lists(_ key: String) -> Bool { counts[key] != nil }

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

    /// The index starts over from no records (``StoreIndex/rebuild(_:)``).
    func beginRebuild() {
        guard beforeRebuild == nil else { return }
        beforeRebuild = counts
        counts.removeAll(keepingCapacity: true)
    }

    /// The rebuild indexed its records: reports the keys it dropped and the ones it added.
    func endRebuild() {
        guard let previous: [String: Int] = beforeRebuild else { return }
        beforeRebuild = nil
        guard let onChange else { return }
        for key in previous.keys where counts[key] == nil { onChange(key, .dropped) }
        for key in counts.keys where previous[key] == nil { onChange(key, .listed) }
    }

    private func count(_ key: String, by step: Int) {
        let before = counts[key] ?? 0
        let after = max(before + step, 0)
        counts[key] = after > 0 ? after : nil
        guard beforeRebuild == nil, (before == 0) != (after == 0) else { return }
        onChange?(key, after > 0 ? .listed : .dropped)
    }
}
