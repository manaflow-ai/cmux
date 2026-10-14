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
/// page tabs, page titles) are applied on every publish by
/// `ControlTopologyMapper.applyAppFacts`, as before the cache, from the
/// panes and page tabs the entry captured (`ControlPaneSlot`): a publish
/// reads no tree property of an unchanged workspace, so its Observation
/// access list does not grow with every tab (cx-1ox9m).
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

    public init() {}

    /// The control value of `model` and its pane slots, from the cache when
    /// nothing their build read changed.
    func info(for model: WorkspaceModel, build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]]),
              counted: Bool = true) -> (info: ControlWorkspaceInfo, slots: [[ControlPaneSlot]]) {
        let key = ObjectIdentifier(model)
        if let entry = entries[key], entry.model === model,
           !stale.withLock({ $0.contains(entry.generation) }) {
            if counted { see(entry) }
            return (entry.info, entry.slots)
        }
        if let old = entries[key] { stale.withLock { _ = $0.remove(old.generation) } }
        nextGeneration += 1
        let generation = nextGeneration
        let (info, slots) = withObservationTracking { build(model) } onChange: { [weak self] in
            self?.stale.withLock { _ = $0.insert(generation) }
            // Runs synchronously inside the mutation; publish after it lands.
            // task-owner: none needed; a one-shot hop that holds the cache weakly and ends after one publish.
            Task { @MainActor in self?.onStale() }
        }
        let entry = Entry(model: model, info: info, slots: slots, generation: generation)
        entries[key] = entry
        if counted { see(entry) } else { entry.pass = pass }
        return (info, slots)
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
        stale.withLock { set in dropped.values.forEach { set.remove($0.generation) } }
        entries = entries.filter { keep.contains($0.key) }
    }

    // MARK: The workspace list

    /// The last list `workspaceList` mapped: its models, their entries and
    /// the published values (daemon facts plus app facts), index by index.
    private var listModels: [WorkspaceModel] = []
    private var listEntries: [Entry] = []
    private var listInfos: [ControlWorkspaceInfo] = []
    /// List index of each entry generation and of each pane id (from the
    /// entry's slots), and the indices whose slots hold store page tabs.
    private var listIndexOfGeneration: [UInt64: Int] = [:]
    private var listIndexOfPane: [String: Int] = [:]
    private var listPageTabIndices: Set<Int> = []
    /// Indices whose published value differs from the entry's daemon facts
    /// (app facts applied): checked again on the next pass.
    private var listAppFactIndices: Set<Int> = []
    private var listIsValid = false
    /// False when the last `workspaceList` call returned the same values as
    /// the one before it (the publisher then may skip an equal publish).
    public private(set) var listChanged = true

    /// The control values of `models` in order, incremental: when the list
    /// holds the same models as the last call, only entries whose tracking
    /// fired are rebuilt and only workspaces that can carry app facts
    /// (`appFactPanes`: the panes with a pane controller or app-only page
    /// tabs; and the workspaces with store page tabs or app facts last time)
    /// get `appFacts` again; the rest reuse the last values (O(n) identity
    /// compares, no map of every workspace). `appFactPanes` nil: every
    /// workspace gets `appFacts`. `appFacts` returns nil when the daemon
    /// facts already hold the app facts. `changed` is false when the result
    /// equals the last call's.
    func workspaceList(_ models: [WorkspaceModel], appFactPanes: Set<String>?,
                       build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]]),
                       appFacts: (WorkspaceModel, ControlWorkspaceInfo, [[ControlPaneSlot]]) -> ControlWorkspaceInfo?)
        -> (infos: [ControlWorkspaceInfo], changed: Bool) {
        guard listIsValid, sameList(models) else { return mapList(models, build: build, appFacts: appFacts) }
        var changed = false
        var rebuilt = Set<Int>()
        let staleGenerations = stale.withLock { $0 }
        for generation in staleGenerations {
            guard let index = listIndexOfGeneration[generation], let model = listModels[checked: index] else { continue }
            _ = info(for: model, build: build, counted: false)
            guard let entry = entries[ObjectIdentifier(model)] else { continue }
            unindex(index)
            listEntries.modify(checked: index) { $0 = entry }
            indexEntry(entry, at: index)
            rebuilt.insert(index)
        }
        var candidates = rebuilt.union(listAppFactIndices).union(listPageTabIndices)
        if let appFactPanes {
            for pane in appFactPanes { if let index = listIndexOfPane[pane] { candidates.insert(index) } }
        } else {
            candidates = Set(listModels.indices)
        }
        for index in candidates {
            guard let entry = listEntries[checked: index] else { continue }
            let value = appFacts(entry.model, entry.info, entry.slots)
            if value != nil { listAppFactIndices.insert(index) } else { listAppFactIndices.remove(index) }
            let next = value ?? entry.info
            if rebuilt.contains(index) || next != listInfos[checked: index] {
                listInfos.modify(checked: index) { $0 = next }
                changed = true
            }
        }
        // Every list model was looked up (retain's coverage count).
        seenThisPass += listModels.count
        listChanged = changed
        return (listInfos, changed)
    }

    private func sameList(_ models: [WorkspaceModel]) -> Bool {
        guard models.count == listModels.count else { return false }
        for (model, listed) in zip(models, listModels) where model !== listed { return false }
        return true
    }

    /// Maps every model (the list changed): cached entries are reused, the
    /// stale ones rebuilt, and the list indexes are made again.
    private func mapList(_ models: [WorkspaceModel], build: (WorkspaceModel) -> (ControlWorkspaceInfo, [[ControlPaneSlot]]),
                         appFacts: (WorkspaceModel, ControlWorkspaceInfo, [[ControlPaneSlot]]) -> ControlWorkspaceInfo?)
        -> (infos: [ControlWorkspaceInfo], changed: Bool) {
        listIndexOfGeneration.removeAll(keepingCapacity: true)
        listIndexOfPane.removeAll(keepingCapacity: true)
        listPageTabIndices.removeAll(keepingCapacity: true)
        listAppFactIndices.removeAll(keepingCapacity: true)
        var entriesOut: [Entry] = []
        var infos: [ControlWorkspaceInfo] = []
        entriesOut.reserveCapacity(models.count)
        infos.reserveCapacity(models.count)
        for model in models {
            _ = info(for: model, build: build)
            guard let entry = entries[ObjectIdentifier(model)] else { continue }
            let index = entriesOut.count
            entriesOut.append(entry)
            indexEntry(entry, at: index)
            let value = appFacts(model, entry.info, entry.slots)
            if value != nil { listAppFactIndices.insert(index) }
            infos.append(value ?? entry.info)
        }
        listModels = models
        listEntries = entriesOut
        listIsValid = entriesOut.count == models.count
        listInfos = infos
        listChanged = true
        return (infos, true)
    }

    private func indexEntry(_ entry: Entry, at index: Int) {
        listIndexOfGeneration[entry.generation] = index
        var hasPageTabs = false
        for screen in entry.slots {
            for slot in screen {
                listIndexOfPane[slot.pane.id] = index
                if !slot.pageTabs.isEmpty { hasPageTabs = true }
            }
        }
        if hasPageTabs { listPageTabIndices.insert(index) } else { listPageTabIndices.remove(index) }
    }

    private func unindex(_ index: Int) {
        guard let entry = listEntries[checked: index] else { return }
        listIndexOfGeneration[entry.generation] = nil
        for screen in entry.slots {
            for slot in screen where listIndexOfPane[slot.pane.id] == index { listIndexOfPane[slot.pane.id] = nil }
        }
        listPageTabIndices.remove(index)
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

    /// Drops the memos whose slot is not in `slots` (closed windows).
    public func retainMemos(_ slots: Set<String>) {
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
