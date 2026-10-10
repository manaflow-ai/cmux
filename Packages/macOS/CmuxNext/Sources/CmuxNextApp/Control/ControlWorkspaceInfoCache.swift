import CmuxNextControl
import CmuxNextDaemon
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
/// `ControlTopologyMapper.applyAppFacts`, as before the cache.
///
/// Each entry is built inside its own Observation tracking; the first change
/// to anything the build read (the workspace, its panes and tabs, the pane's
/// shown tab, page facts) marks the entry stale synchronously, inside the
/// mutation, so the next publish rebuilds it even when it runs on the same
/// turn (a compat read after a write). The entry holds its model, so the
/// model's identity cannot be reused while the entry exists; entries of
/// models no longer listed are dropped on each publish.
@MainActor
final class ControlWorkspaceInfoCache {
    private struct Entry {
        let model: WorkspaceModel
        let info: ControlWorkspaceInfo
        let generation: UInt64
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    /// Generations whose tracking fired; written inside the mutation.
    private nonisolated let stale = Mutex<Set<UInt64>>([])
    /// Runs after an entry went stale: cached entries are not re-read by the
    /// publisher's own tracking, so their changes must schedule the publish.
    var onStale: @MainActor () -> Void = {}

    /// The control value of `model`, from the cache when nothing it read changed.
    func info(for model: WorkspaceModel, build: (WorkspaceModel) -> ControlWorkspaceInfo) -> ControlWorkspaceInfo {
        let key = ObjectIdentifier(model)
        if let entry = entries[key], entry.model === model,
           !stale.withLock({ $0.contains(entry.generation) }) {
            return entry.info
        }
        if let old = entries[key] { stale.withLock { _ = $0.remove(old.generation) } }
        nextGeneration += 1
        let generation = nextGeneration
        let info = withObservationTracking { build(model) } onChange: { [weak self] in
            self?.stale.withLock { _ = $0.insert(generation) }
            // Runs synchronously inside the mutation; publish after it lands.
            Task { @MainActor in self?.onStale() }
        }
        entries[key] = Entry(model: model, info: info, generation: generation)
        return info
    }

    /// Drops the entries of models not in `live` (closed workspaces, a
    /// reconnect that replaced the models).
    func retain(_ live: [WorkspaceModel]) {
        let keep = Set(live.map(ObjectIdentifier.init))
        let dropped = entries.filter { !keep.contains($0.key) }
        guard !dropped.isEmpty else { return }
        stale.withLock { set in dropped.values.forEach { set.remove($0.generation) } }
        entries = entries.filter { keep.contains($0.key) }
    }
}
