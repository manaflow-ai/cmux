public import CmuxNextDaemon
import Observation
import CmuxNextCompat

/// Keeps each workspace's control value between snapshot publishes
/// (plans/cmux-next/control-snapshot-topology.md, step 1). A publish maps
/// only the workspaces that changed since the last one, instead of every
/// workspace, screen, pane and tab on each settled frame (cx-9c8m).
///
/// Entries hold only daemon-mirror facts (all @Observable). App facts that
/// Observation does not track (the tab a window shows for a pane, app-only
/// page tabs, page titles) are applied by `ControlTopologyMapper.applyAppFacts`
/// from the panes and page tabs the entry captured (`ControlPaneSlot`): a
/// publish reads no tree property of an unchanged workspace, so its
/// Observation access list does not grow with every tab (cx-1ox9m).
///
/// With a ``ControlAppFactScope`` the cache also keeps each store's mapped
/// list (`ControlWorkspaceList`): a publish then visits only the workspaces
/// whose entry went stale and the ones the scope names, not every workspace
/// (sidebar churn bench, 400 workspaces: 9% of main). Without a scope every
/// publish applies app facts to every workspace, as before.
///
/// Each entry is built inside its own Observation tracking; the first change
/// to anything the build read (the workspace, its panes and tabs, the pane's
/// shown tab, page facts) marks the entry stale synchronously, inside the
/// mutation, so the next publish rebuilds it even when it runs on the same
/// turn (a compat read after a write). The entry holds its model, so the
/// model's identity cannot be reused while the entry exists; entries of
/// models no longer listed are dropped on each publish.
@MainActor
public final class ControlWorkspaceInfoCache {
    /// A class: every publish looks up every entry, and a struct lookup
    /// copied the whole value (retains of every array in it) each time.
    private final class Entry {
        let model: WorkspaceModel
        let info: ControlWorkspaceInfo
        let slots: [[ControlPaneSlot]]
        let generation: UInt64
        /// The last `retain` pass that looked this entry up.
        var pass: UInt64 = 0

        init(model: WorkspaceModel, info: ControlWorkspaceInfo, slots: [[ControlPaneSlot]], generation: UInt64) {
            self.model = model
            self.info = info
            self.slots = slots
            self.generation = generation
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Lookups since the last `retain` (each entry counted once): when they
    /// cover every entry, `retain` has nothing to drop.
    private var pass: UInt64 = 1
    private var seenThisPass = 0
    private var nextGeneration: UInt64 = 0
    /// Generations whose tracking fired; written inside the mutation.
    private nonisolated let stale = Mutex<Set<UInt64>>([])
    /// Runs after an entry went stale: cached entries are not re-read by the
    /// publisher's own tracking, so their changes must schedule the publish.
    public var onStale: @MainActor () -> Void = {}
    /// Workspaces a topology pass looked up, rebuilt or applied app facts
    /// to, since the cache was made (tests read the per-publish delta).
    private(set) var workspaceVisits = 0
    /// Tabs in the lists the last publish mapped (``ControlTopology/tabCount`` of their
    /// workspaces), kept as entries change instead of walking every tab.
    public var tabCount: Int { lists.values.reduce(0) { $0 + $1.tabCount } }
    /// Memo values built (not reused) since the cache was made (tests read the per-publish delta).
    private(set) var memoBuilds = 0

    public init() {}

    /// The control value of `model` and its pane slots, from the cache when
    /// nothing their build read changed.
    func info(for model: WorkspaceModel, build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]]))
        -> (info: ControlWorkspaceInfo, slots: [[ControlPaneSlot]]) {
        let entry = entry(for: model, build: build)
        see(entry)
        return (entry.info, entry.slots)
    }

    /// `model`'s entry, rebuilt when anything its last build read changed.
    private func entry(for model: WorkspaceModel, build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]])) -> Entry {
        workspaceVisits += 1
        let key = ObjectIdentifier(model)
        if let entry = entries[key], entry.model === model,
           !stale.withLock({ $0.contains(entry.generation) }) {
            return entry
        }
        if let old = entries[key] { forgetEntry(old) }
        let generation = track()
        let (info, slots) = withObservationTracking { build(model) } onChange: { [weak self] in
            self?.fired(generation)
        }
        let entry = Entry(model: model, info: info, slots: slots, generation: generation)
        entries[key] = entry
        owners[generation] = key
        return entry
    }

    /// A new tracking generation.
    private func track() -> UInt64 {
        nextGeneration += 1
        return nextGeneration
    }

    /// Marks `generation` stale and schedules a publish. Runs synchronously
    /// inside the mutation that fired the tracking.
    private nonisolated func fired(_ generation: UInt64) {
        stale.withLock { _ = $0.insert(generation) }
        // Runs synchronously inside the mutation; publish after it lands.
        // task-owner: none needed; a one-shot hop that holds the cache weakly and ends after one publish.
        Task { @MainActor [weak self] in self?.onStale() }
    }

    private func forgetEntry(_ entry: Entry) {
        stale.withLock { _ = $0.remove(entry.generation) }
        owners[entry.generation] = nil
    }

    // MARK: Lists

    /// The slot ``ControlTopology/init(store:selectedTab:pages:cache:scope:)``
    /// keeps its store's list under; other stores use other slots.
    public static let homeSlot = "home"

    /// Each store's list as the last publish mapped it, by slot.
    private var lists: [String: ControlWorkspaceList] = [:]
    /// The model of each live entry generation.
    private var owners: [UInt64: ObjectIdentifier] = [:]

    /// The control values of the workspaces `read` lists, in order, as
    /// `appFacts` completes them for the workspaces in `scope`.
    ///
    /// Kept between publishes under `slot` (one per store). A publish visits
    /// only the workspaces whose daemon facts changed, the ones in `scope`
    /// (or in the last publish's scope), and the ones with store page tabs;
    /// a changed list maps every workspace once. Every other value is its
    /// cached daemon value, which equals what `appFacts` makes of it when the
    /// scope is complete.
    func workspaces(slot: String, list read: () -> [WorkspaceModel], scope: ControlAppFactScope,
                    build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]]),
                    appFacts: (WorkspaceModel, ControlWorkspaceInfo, [[ControlPaneSlot]]) -> ControlWorkspaceInfo)
        -> [ControlWorkspaceInfo] {
        let list = lists[slot] ?? ControlWorkspaceList()
        lists[slot] = list
        let listChanged = list.generation.map { generation in stale.withLock { $0.remove(generation) != nil } } ?? true
        if listChanged {
            let generation = track()
            let models = withObservationTracking(read, onChange: { [weak self] in self?.fired(generation) })
            list.generation = generation
            if !models.elementsEqual(list.models, by: ===) { remap(list, to: models, build: build) }
        }
        patchStale(list, build: build)
        var scoped = list.pageTabWorkspaces
        for model in scope.shown {
            let key = ObjectIdentifier(model)
            if list.contains(key) { scoped.insert(key) }
        }
        for id in scope.paneIDs {
            if let key = list.paneOwners[id] { scoped.insert(key) }
        }
        for key in scoped.union(list.applied) {
            guard let position = list.index[key], let entry = entries[key] else { continue }
            workspaceVisits += 1
            let info = scoped.contains(key) ? appFacts(entry.model, entry.info, entry.slots) : entry.info
            list.infos.modify(checked: position) { $0 = info }
        }
        list.applied = scoped
        return list.infos
    }

    /// Maps `models` whole: the list changed (added, closed, reordered or
    /// replaced workspaces). Drops the entries of models no longer listed.
    private func remap(_ list: ControlWorkspaceList, to models: [WorkspaceModel],
                       build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]])) {
        var index: [ObjectIdentifier: Int] = [:]
        index.reserveCapacity(models.count)
        list.infos = []
        list.infos.reserveCapacity(models.count)
        list.paneOwners = [:]
        list.pageTabWorkspaces = []
        list.tabCount = 0
        for (position, model) in models.enumerated() {
            let entry = entry(for: model, build: build)
            let key = ObjectIdentifier(model)
            index[key] = position
            list.infos.append(entry.info)
            list.tabCount += Self.tabs(of: entry.info)
            own(entry, key, in: list)
        }
        for key in list.index.keys where index[key] == nil {
            if let entry = entries.removeValue(forKey: key) { forgetEntry(entry) }
        }
        list.models = models
        list.index = index
        list.applied = []
    }

    /// Rebuilds the entries of `list` whose tracking fired and patches their values in.
    private func patchStale(_ list: ControlWorkspaceList, build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]])) {
        let fired = stale.withLock { $0 }
        guard !fired.isEmpty else { return }
        let liveLists = Set(lists.values.compactMap(\.generation))
        var dead: [UInt64] = []
        for generation in fired {
            guard let key = owners[generation] else {
                // A dropped entry's or replaced list's tracking: nothing to rebuild.
                if !liveLists.contains(generation) { dead.append(generation) }
                continue
            }
            guard let position = list.index[key], let old = entries[key] else { continue }
            for pane in old.info.screens.flatMap(\.panes) where list.paneOwners[pane.id] == key {
                list.paneOwners[pane.id] = nil
            }
            list.pageTabWorkspaces.remove(key)
            let entry = entry(for: old.model, build: build)
            list.tabCount += Self.tabs(of: entry.info) - Self.tabs(of: old.info)
            list.infos.modify(checked: position) { $0 = entry.info }
            list.applied.remove(key)
            own(entry, key, in: list)
        }
        if !dead.isEmpty { stale.withLock { set in dead.forEach { set.remove($0) } } }
    }

    /// The tabs of `info`'s panes.
    private static func tabs(of info: ControlWorkspaceInfo) -> Int {
        info.screens.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabs.count } }
    }

    /// Records `entry`'s panes and page tabs in `list`.
    private func own(_ entry: Entry, _ key: ObjectIdentifier, in list: ControlWorkspaceList) {
        for screen in entry.info.screens {
            for pane in screen.panes { list.paneOwners[pane.id] = key }
        }
        if entry.slots.contains(where: { $0.contains { !$0.pageTabs.isEmpty } }) { list.pageTabWorkspaces.insert(key) }
    }

    /// Drops the lists whose slot is not in `slots` (a disconnected session)
    /// and their entries.
    public func retainLists(_ slots: Set<String>) {
        guard lists.keys.contains(where: { !slots.contains($0) }) else { return }
        for (slot, list) in lists where !slots.contains(slot) {
            for key in list.index.keys {
                if let entry = entries.removeValue(forKey: key) { forgetEntry(entry) }
            }
            if let generation = list.generation { stale.withLock { _ = $0.remove(generation) } }
            lists[slot] = nil
        }
    }

    private func see(_ entry: Entry) {
        guard entry.pass != pass else { return }
        entry.pass = pass
        seenThisPass += 1
    }

    /// Drops the entries of models not in `live` (closed workspaces, a
    /// reconnect that replaced the models). Every publish calls it: when
    /// each live model has its entry and there are no others (the usual
    /// case), it returns without building a set (O(n) lookups, no allocation).
    public func retain(_ live: [WorkspaceModel]) {
        // The publisher looks up every live model before it calls this: when
        // the lookups since the last call covered every entry and as many
        // models are live, nothing is dropped (O(1); a per-model check here
        // cost more than the rest of a publish in debug builds).
        let covered = seenThisPass == entries.count && live.count == entries.count
        pass &+= 1
        seenThisPass = 0
        if covered { return }
        let keep = Set(live.map(ObjectIdentifier.init))
        let dropped = entries.filter { !keep.contains($0.key) }
        guard !dropped.isEmpty else { return }
        dropped.values.forEach(forgetEntry)
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: Derived values

    private struct Memo {
        let key: Any
        let value: Any
        let generation: UInt64
    }

    /// Generations of the memos in `memos` (live) and the live ones whose
    /// tracking fired (stale); written inside the mutation. A replaced or
    /// dropped memo leaves `live`, so its tracking firing later marks nothing
    /// and schedules no publish.
    private struct MemoGenerations: Sendable {
        var live: Set<UInt64> = []
        var stale: Set<UInt64> = []
    }

    private var memos: [String: Memo] = [:]
    private nonisolated let memoGenerations = Mutex(MemoGenerations())

    /// A value derived from many models (for example a window's visible
    /// workspaces), kept between publishes like the workspace entries: built
    /// inside its own Observation tracking, rebuilt when `key` changes or when
    /// anything the build read changed (which also schedules a publish, as
    /// for an entry). A publish that reuses it reads none of its models, so
    /// the publisher's tracking does not hold one access per workspace (a
    /// rebuild still adds its reads there: nested tracking merges into the
    /// outer one). A large access list made every publish, and the first
    /// change after one, O(workspaces) (1,000 workspaces, 2026-10-14 profile).
    /// `key` is compared with its own `==` (an `AnyHashable` array compare
    /// boxed every element).
    public func memo<Key: Equatable, Value>(_ slot: String, key: Key, build: () -> Value) -> Value {
        if let memo = memos[slot], let old = memo.key as? Key, old == key, let value = memo.value as? Value,
           !memoGenerations.withLock({ $0.stale.contains(memo.generation) }) {
            return value
        }
        if let old = memos[slot] { forget(old.generation) }
        memoBuilds += 1
        nextGeneration += 1
        let generation = nextGeneration
        memoGenerations.withLock { _ = $0.live.insert(generation) }
        let value = withObservationTracking { build() } onChange: { [weak self] in
            guard let self else { return }
            let live = self.memoGenerations.withLock { state in
                guard state.live.contains(generation) else { return false }
                state.stale.insert(generation)
                return true
            }
            // task-owner: none needed; a one-shot hop that holds the cache weakly and ends after one publish.
            if live { Task { @MainActor [weak self] in self?.onStale() } }
        }
        memos[slot] = Memo(key: key, value: value, generation: generation)
        return value
    }

    /// The slot of ``closedTabs(_:)``, which `retainMemos` always keeps.
    private static let closedTabsSlot = "tabSearch.closed"

    /// Search Tabs' closed tabs, kept like a ``memo(_:key:build:)``: `build` runs again only when
    /// something it read changed. The publisher rebuilt them on every publish (about 10% of main
    /// while idle on cmux8s, sidebar-churn bench).
    ///
    /// - Parameter build: makes the list from the App's owners (closed items, machines).
    /// - Returns: the kept or newly built list.
    public func closedTabs(_ build: () -> [ControlClosedTab]) -> [ControlClosedTab] {
        memo(Self.closedTabsSlot, key: 0, build: build)
    }

    /// Drops the memos whose slot is not in `slots` (closed windows); ``closedTabs(_:)`` stays.
    public func retainMemos(_ slots: Set<String>) {
        let slots = slots.union([Self.closedTabsSlot])
        guard memos.keys.contains(where: { !slots.contains($0) }) else { return }
        for (slot, memo) in memos where !slots.contains(slot) {
            forget(memo.generation)
            memos[slot] = nil
        }
    }

    private func forget(_ generation: UInt64) {
        memoGenerations.withLock { state in
            state.live.remove(generation)
            state.stale.remove(generation)
        }
    }
}
