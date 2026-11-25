import CmuxNextCompat
public import CmuxNextDaemon
import CryptoKit
import Foundation

/// Keeps ``AgentPaneAttentionTabs`` (every agent page's Needs you list) and the palette's Go to
/// What Needs Me on the tabs an agent marked (`tab-attention-v1`, `cmux attention request`), on
/// every connected machine. One observation per workspace (main-thread-scheduling.md section 3, O3):
/// each workspace's marks are their own observation, and the watch's own stream reads only each
/// machine's readiness and its workspace list, so a mark on one tab re-reads its workspace only.
/// The work after that one mark follows the marked tabs (the list a person sees), never the session's size: the
/// changed workspace's marks arrive as one change, and the list is joined from the workspaces that have a mark.
/// Only a marked tab's titles are read, so a title change of any other tab wakes nothing; nothing polls.
@MainActor
public final class AttentionTabsWatch {
    /// One machine's observed state, including readiness so an empty initial snapshot still
    /// wakes the consumer. Tab attention arrives on the session stream, after or before the tree.
    public nonisolated struct Snapshot: Hashable, Sendable {
        public var machine: String
        public var epoch: Int
        public var stateGeneration: UInt64
        public var storeID: ObjectIdentifier
        public var ready: Bool
        public var items: [AgentPaneAttentionTabs.Item]
        /// The marked tabs' requests that were already in this connection's session snapshot (the launch baseline).
        public var baselineRequests: Set<String>

        /// One machine's state read now, every workspace at once (tests and one-shot reads; the watch reads each
        /// workspace's marks in its own observation).
        @MainActor public init(machine: String, store: DaemonStore) {
            self.init(header: Header(machine: machine, store: store),
                      marks: store.workspaces.map { AttentionTabsWatch.marks(of: $0, machine: machine, store: store) })
        }

        init(header: Header, marks: [WorkspaceMarks]) {
            machine = header.machine
            epoch = header.epoch
            stateGeneration = header.stateGeneration
            storeID = header.storeID
            ready = header.ready
            items = marks.flatMap(\.items).sorted { $0.atMs > $1.atMs }
            baselineRequests = marks.reduce(into: []) { $0.formUnion($1.baseline) }
        }
    }

    /// A machine's store-level state: its connection, readiness and snapshot generation, no workspace.
    nonisolated struct Header: Hashable, Sendable {
        var machine: String
        var epoch: Int
        var stateGeneration: UInt64
        var storeID: ObjectIdentifier
        var ready: Bool

        @MainActor init(machine: String, store: DaemonStore) {
            self.machine = machine
            epoch = store.connectionEpoch
            stateGeneration = store.session.snapshotGeneration
            storeID = ObjectIdentifier(store)
            // Observe connection state too: connectionEpoch intentionally is not observed.
            let connected: Bool
            if case .connected = store.connectionState { connected = true } else { connected = false }
            ready = connected && store.isLoaded && !store.isProvisional
                && store.liveTreeEpoch == epoch && store.session.known
                && (!store.servesStateResources || store.session.hasCurrentSnapshot)
        }
    }

    /// One workspace's marked tabs and their launch-baseline requests.
    nonisolated struct WorkspaceMarks: Hashable, Sendable {
        var items: [AgentPaneAttentionTabs.Item]
        var baseline: Set<String>
    }

    /// The machines the watch follows: each one's id and store.
    public typealias Machine = (machine: String, store: DaemonStore)

    /// The observation loop. AppServices owns the watch; releasing it cancels the stream.
    private let task: Task<Void, Never>

    /// Nil machines means the composition-root owner is gone. Every list reaches the lifecycle
    /// callback, with posting disabled while loading and for each connection's initial baseline.
    public init(tabs: AgentPaneAttentionTabs,
                machines: @escaping @MainActor () -> [Machine]?,
                onChange: @escaping @MainActor ([AgentPaneAttentionTabs.Item], Set<String>) -> Void) {
        let marks = Marks(tabs: tabs, onChange: onChange)
        // task-owner: AppServices.attentionTabsWatch; cancelled in deinit, or when machines returns nil
        task = Task {
            for await trigger in ObservationStream({ () -> ObservationTrigger<[Listed]?> in
                // Each machine's readiness and workspace list; no workspace's fields (their marks are their own observations).
                ObservationTrigger(machines()?.map { Listed(header: Header(machine: $0.machine, store: $0.store), store: $0.store,
                                                            workspaces: $0.store.workspaces) })
            }) {
                guard let listed = trigger.value else {
                    marks.stop()
                    return
                }
                marks.listed = listed
                marks.settle()
            }
        }
    }

    // cx-t7hu: nonisolated; the task is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { task.cancel() }

    /// One listed machine: its header when listed, its store and its workspaces.
    nonisolated struct Listed: Sendable {
        var header: Header
        var store: DaemonStore
        var workspaces: [WorkspaceModel]
    }

    /// The watch's state: each machine's per-workspace observations, the snapshots delivered last and the baseline.
    @MainActor private final class Marks {
        let tabs: AgentPaneAttentionTabs
        let onChange: @MainActor ([AgentPaneAttentionTabs.Item], Set<String>) -> Void
        var listed: [Listed] = []
        /// By machine and store: one observation per workspace of its marks.
        private var observed: [String: ObservedItems<WorkspaceModel, WorkspaceMarks>] = [:]
        private var headers: [String: Header] = [:]
        /// By machine and store: what its workspaces' observations handed out last.
        private var held: [String: Held] = [:]
        private var last: [Snapshot]?
        private var baseline = SnapshotBaseline()

        /// One machine's marks: each listed workspace's (in list order), and the places of the workspaces with a marked tab.
        private struct Held {
            var all: [WorkspaceMarks]
            var marked: SortedPositions
        }

        init(tabs: AgentPaneAttentionTabs, onChange: @escaping @MainActor ([AgentPaneAttentionTabs.Item], Set<String>) -> Void) {
            self.tabs = tabs
            self.onChange = onChange
        }

        private static func key(_ machine: String, _ store: DaemonStore) -> String { "\(machine)\t\(ObjectIdentifier(store))" }

        /// A machine's readiness or its workspace list changed: the snapshots now. A machine whose header changed (a
        /// connect, a new session snapshot, readiness) reads every workspace's marks again at once, untracked, so its
        /// header and marks come from one moment as the replay baseline needs; otherwise only workspaces new to the list
        /// are read (their observations keep the rest). Every listed workspace is visited, so this is never the path of
        /// one workspace's mark (``itemChanged(_:machine:store:_:)``).
        func settle() {
            var kept: Set<String> = []
            for machine in listed {
                let key = Self.key(machine.header.machine, machine.store)
                kept.insert(key)
                let header = Header(machine: machine.header.machine, store: machine.store)
                let items = observed[key] ?? start(key, machine: machine.header.machine, store: machine.store)
                let refresh = headers[key] != header
                headers[key] = header
                let all = items.items(for: machine.workspaces, id: { "\(ObjectIdentifier($0))" }, refresh: refresh)
                var marked = SortedPositions()
                for position in all.indices where !all[position].items.isEmpty { marked.insert(position) }
                held[key] = Held(all: all, marked: marked)
            }
            for key in observed.keys where !kept.contains(key) {
                observed.removeValue(forKey: key)?.cancelAll()
                headers[key] = nil
                held[key] = nil
            }
            deliver()
        }

        /// One workspace's marks changed: its place gets them, and the list is joined again from the workspaces with a
        /// mark. A machine whose header moved in the same turn takes ``settle()`` instead, so its header and marks still
        /// come from one moment.
        private func itemChanged(_ key: String, machine: String, store: DaemonStore?,
                                 _ change: ObservedItems<WorkspaceModel, WorkspaceMarks>.Change) {
            guard let store, headers[key] == Header(machine: machine, store: store),
                  held[key]?.all.indices.contains(change.position) == true else { return settle() }
            held[key]?.all[change.position] = change.new
            if change.new.items.isEmpty { held[key]?.marked.remove(change.position) } else { held[key]?.marked.insert(change.position) }
            deliver()
        }

        /// Delivers the snapshots of the listed machines when they changed. A snapshot is joined from the workspaces
        /// with a marked tab only: a workspace with no mark has no item and no baseline request
        /// (``AttentionTabsWatch/marks(of:machine:store:)``), so the result is that of a join of every workspace.
        private func deliver() {
            var snapshots: [Snapshot] = []
            var joined = 0
            for machine in listed {
                let key = Self.key(machine.header.machine, machine.store)
                guard let header = headers[key], let marks = held[key] else { continue }
                joined += marks.marked.count
                snapshots.append(Snapshot(header: header, marks: marks.marked.positions.map { marks.all[$0] }))
            }
            ObservationWork.visited(joined, "AttentionTabsWatch.join")
            guard snapshots != last else { return }
            last = snapshots
            let marked = snapshots.flatMap(\.items).sorted { $0.atMs > $1.atMs }
            tabs.items = marked
            onChange(marked, baseline.eligibleRequests(snapshots))
        }

        private func start(_ key: String, machine: String, store: DaemonStore) -> ObservedItems<WorkspaceModel, WorkspaceMarks> {
            let items = ObservedItems<WorkspaceModel, WorkspaceMarks>(
                item: { [weak store] workspace in store.map { AttentionTabsWatch.marks(of: workspace, machine: machine, store: $0) } },
                same: { $0 == $1 },
                changedItem: { [weak self, weak store] change in self?.itemChanged(key, machine: machine, store: store, change) })
            observed[key] = items
            return items
        }

        func stop() {
            for items in observed.values { items.cancelAll() }
            observed = [:]
            headers = [:]
            held = [:]
            listed = []
        }
    }

    /// Each machine establishes its own baseline. An offline remote never suppresses a new
    /// local request. Store replacement, reconnect and session-stream replay all rebaseline.
    public nonisolated struct SnapshotBaseline: Sendable {
        private var previous: [String: Snapshot] = [:]
        private var reported: [String: Set<String>] = [:]

        public init() {}

        public mutating func eligibleRequests(_ snapshots: [Snapshot]) -> Set<String> {
            var eligible: Set<String> = []
            let present = Set(snapshots.map(\.machine))
            reported = reported.filter { present.contains($0.key) }
            for snapshot in snapshots {
                let old = previous[snapshot.machine]
                if old?.storeID != snapshot.storeID || old?.epoch != snapshot.epoch
                    || old?.stateGeneration != snapshot.stateGeneration {
                    reported[snapshot.machine] = []
                }
                guard snapshot.ready else { continue }
                let current = Set(snapshot.items.map(\.tabId))
                // Eligibility comes from the session snapshot, not the last observation:
                // a delta may precede tree readiness or coalesce with the initial snapshot.
                let candidates = current.subtracting(snapshot.baselineRequests)
                let new = candidates.subtracting(reported[snapshot.machine] ?? [])
                eligible.formUnion(new)
                // Only live candidates are retained; clears and machine removal bound memory.
                reported[snapshot.machine] = candidates
            }
            previous = Dictionary(snapshots.map { ($0.machine, $0) }, uniquingKeysWith: { _, last in last })
            return eligible
        }
    }

    /// The marked tabs of `workspaces` (each with the id of the machine that holds it), newest
    /// mark first: the agent's reason, the workspace and tab titles the person knows them by (never
    /// an id), and when it was marked. Each row's key is ``key(machine:tab:requestID:)``.
    public static func items(in workspaces: [(WorkspaceModel, machine: String)]) -> [AgentPaneAttentionTabs.Item] {
        workspaces.flatMap { workspace, machine in items(of: workspace, machine: machine) }.sorted { $0.atMs > $1.atMs }
    }

    /// One workspace's marked tabs (each with the id of the machine that holds it), in model order.
    static func items(of workspace: WorkspaceModel, machine: String) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        var workspaceTitle: String?
        for screen in workspace.screens {
            for pane in screen.panes {
                for tab in pane.tabs {
                    guard let attention = tab.attention, let requestID = attention.requestID else { continue }
                    // The workspace's name only once it has a marked tab: an unmarked workspace's rename wakes nothing.
                    let title = workspaceTitle ?? workspace.displayName
                    workspaceTitle = title
                    items.append(AgentPaneAttentionTabs.Item(
                        tabId: key(machine: machine, tab: tab.resourceID?.rawValue ?? tab.id, requestID: requestID), reason: attention.reason,
                        workspaceTitle: title, tabTitle: tab.displayTitle, atMs: attention.atMs))
                }
            }
        }
        return items
    }

    /// One workspace's marked tabs and, of those, the requests already in its machine's session snapshot (the launch
    /// baseline): only a marked tab's request can be a candidate, so no other tab is read past its mark.
    static func marks(of workspace: WorkspaceModel, machine: String, store: DaemonStore) -> WorkspaceMarks {
        let items = items(of: workspace, machine: machine)
        guard !items.isEmpty else { return WorkspaceMarks(items: [], baseline: []) }
        var baseline: Set<String> = []
        for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where tab.attention?.requestID != nil {
            guard let resource = tab.resourceID, let requestID = store.session.snapshotAttention[resource] else { continue }
            baseline.insert(key(machine: machine, tab: resource.rawValue, requestID: requestID))
        }
        return WorkspaceMarks(items: items, baseline: baseline)
    }

    /// A marked tab's row key (`Item.tabId`, what a page's Go to sends back): a short digest of
    /// its machine's id, the attention generation, and its durable tab id, since tabs on two machines can share an id. The
    /// digest keeps the key inside ``AgentPaneAttentionTabs/maximumTabID`` however long the
    /// machine id is, and a tab id holds no `/`.
    public static func key(machine: String, tab: String, requestID: String) -> String { "\(machineDigest(machine))/\(requestID)/\(tab)" }

    /// The first 8 bytes of SHA-256 of `machine`, in hex.
    public static func machineDigest(_ machine: String) -> String {
        SHA256.hash(data: Data(machine.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The machine (of `daemons`) and tab id that row key `key` names; nil for a key that names
    /// no connected machine.
    public static func locate<Daemon>(_ key: String, in daemons: [Daemon], machineID: (Daemon) -> String) -> (daemon: Daemon, tab: String, requestID: String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, TabAttention.validRequestID(String(parts[1])) else { return nil }
        let digest = parts[0], tab = String(parts[2])
        guard !tab.isEmpty, let daemon = daemons.first(where: { machineDigest(machineID($0)) == digest }) else { return nil }
        return (daemon, tab, String(parts[1]))
    }
}
