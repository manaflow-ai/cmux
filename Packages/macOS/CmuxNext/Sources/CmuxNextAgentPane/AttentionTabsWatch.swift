import CmuxNextCompat
public import CmuxNextDaemon
import CryptoKit
import Foundation

/// Keeps ``AgentPaneAttentionTabs`` (every agent page's Needs you list) and the palette's Go to
/// What Needs Me on the tabs an agent marked (`tab-attention-v1`, `cmux attention request`), on
/// every connected machine. Observes the store reads ``items(in:)`` makes, re-armed after each
/// change; nothing polls. Only a marked tab's titles are read, so a title change of any other tab
/// wakes nothing.
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
        public var baselineRequests: Set<String>

        @MainActor public init(machine: String, store: DaemonStore) {
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
            items = AttentionTabsWatch.items(in: store.workspaces.map { ($0, machine: machine) })
            baselineRequests = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
                guard let resource = tab.resourceID, let requestID = store.session.snapshotAttention[resource] else { return nil }
                return AttentionTabsWatch.key(machine: machine, tab: resource.rawValue, requestID: requestID)
            })
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

    /// The observation loop. AppServices owns the watch; releasing it cancels the stream.
    private let task: Task<Void, Never>

    /// Nil snapshots means the composition-root owner is gone. Every list reaches the lifecycle
    /// callback, with posting disabled while loading and for each connection's initial baseline.
    public init(tabs: AgentPaneAttentionTabs,
                snapshots: @escaping @MainActor () -> [Snapshot]?,
                onChange: @escaping @MainActor ([AgentPaneAttentionTabs.Item], Set<String>) -> Void) {
        // task-owner: AppServices.attentionTabsWatch; cancelled in deinit, or when snapshots returns nil
        task = Task {
            var baseline = SnapshotBaseline()
            for await snapshots in ObservationStream(snapshots) {
                guard let snapshots else { return }
                let marked = snapshots.flatMap(\.items).sorted { $0.atMs > $1.atMs }
                tabs.items = marked
                onChange(marked, baseline.eligibleRequests(snapshots))
            }
        }
    }

    // cx-t7hu: nonisolated; the task is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { task.cancel() }

    /// The marked tabs of `workspaces` (each with the id of the machine that holds it), newest
    /// mark first: the agent's reason, the workspace and tab titles the person knows them by (never
    /// an id), and when it was marked. Each row's key is ``key(machine:tab:requestID:)``.
    public static func items(in workspaces: [(WorkspaceModel, machine: String)]) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        for (workspace, machine) in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let attention = tab.attention, let requestID = attention.requestID else { continue }
                        items.append(AgentPaneAttentionTabs.Item(
                            tabId: key(machine: machine, tab: tab.resourceID?.rawValue ?? tab.id, requestID: requestID), reason: attention.reason, workspaceTitle: workspace.displayName,
                            tabTitle: tab.displayTitle, atMs: attention.atMs))
                    }
                }
            }
        }
        return items.sorted { $0.atMs > $1.atMs }
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
