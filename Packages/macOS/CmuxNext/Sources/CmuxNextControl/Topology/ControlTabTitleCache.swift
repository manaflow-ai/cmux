public import CmuxNextDaemon
import CmuxNextCompat
import Observation

/// Search Tabs' agent chat titles (``ControlTabSearchFacts/titles``), kept per workspace between
/// snapshot publishes, like ``ControlWorkspaceInfoCache``'s entries. Each workspace's titles are
/// built inside their own Observation tracking; a change to anything that build read marks that
/// workspace stale and schedules a publish. A publish names the chats of the stale and new
/// workspaces only: before, every publish walked every tab of every workspace and resolved each
/// chat's title under the publisher's tracking, so a tab made in one workspace named the chats of
/// all of them again (ask-bdd706af47).
@MainActor
public final class ControlTabTitleCache {
    private final class Entry {
        let model: WorkspaceModel
        let titles: [String: String]
        let generation: UInt64

        init(model: WorkspaceModel, titles: [String: String], generation: UInt64) {
            self.model = model
            self.titles = titles
            self.generation = generation
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// The workspaces of the last call, in order, and the titles merged from them.
    private var order: [ObjectIdentifier] = []
    private var merged: [String: String] = [:]
    private var nextGeneration: UInt64 = 0
    /// Generations whose tracking fired; written inside the mutation.
    private nonisolated let stale = Mutex<Set<UInt64>>([])
    private let onStale: @MainActor () -> Void

    /// `onStale` runs after a kept workspace's titles went stale (the publisher's tracking does not re-read them).
    public init(onStale: @escaping @MainActor () -> Void) {
        self.onStale = onStale
    }

    /// The titles of every workspace of `workspaces`, by tab id, as one walk in order would make
    /// them (a later workspace's title wins a shared id). `build` makes one workspace's; it runs
    /// only for a workspace that is new or whose last build read something that changed.
    public func titles(_ workspaces: [WorkspaceModel], build: (WorkspaceModel) -> [String: String]) -> [String: String] {
        let fired = stale.withLock { set in
            defer { set.removeAll() }
            return set
        }
        var changed = !order.elementsEqual(workspaces.lazy.map(ObjectIdentifier.init))
        for model in workspaces {
            let key = ObjectIdentifier(model)
            if let entry = entries[key], entry.model === model, !fired.contains(entry.generation) { continue }
            entries[key] = make(model, build: build)
            changed = true
        }
        guard changed else { return merged }
        order = workspaces.map(ObjectIdentifier.init)
        if entries.count != order.count {
            let live = Set(order)
            entries = entries.filter { live.contains($0.key) }
        }
        var titles: [String: String] = [:]
        for key in order {
            guard let entry = entries[key] else { continue }
            titles.merge(entry.titles) { _, later in later }
        }
        merged = titles
        return titles
    }

    private func make(_ model: WorkspaceModel, build: (WorkspaceModel) -> [String: String]) -> Entry {
        nextGeneration &+= 1
        let generation = nextGeneration
        let titles = withObservationTracking { build(model) } onChange: { [weak self] in
            guard let self else { return }
            self.stale.withLock { _ = $0.insert(generation) }
            // task-owner: none needed; a one-shot hop that holds the cache weakly and ends after one publish.
            Task { @MainActor [weak self] in self?.onStale() }
        }
        return Entry(model: model, titles: titles, generation: generation)
    }
}
