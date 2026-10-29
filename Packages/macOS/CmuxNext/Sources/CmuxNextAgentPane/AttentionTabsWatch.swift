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
        }
    }

    /// Each machine establishes its own baseline. An offline remote never suppresses a new
    /// local request. Store replacement, reconnect and session-stream replay all rebaseline.
    public nonisolated struct SnapshotBaseline: Sendable {
        private var previous: [String: Snapshot] = [:]

        public init() {}

        public mutating func eligibleRequests(_ snapshots: [Snapshot]) -> Set<String> {
            var eligible: Set<String> = []
            for snapshot in snapshots {
                if snapshot.ready, let old = previous[snapshot.machine], old.ready,
                   old.storeID == snapshot.storeID, old.epoch == snapshot.epoch,
                   old.stateGeneration == snapshot.stateGeneration {
                    eligible.formUnion(snapshot.items.map(\.tabId))
                }
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
    /// an id), and when it was marked. Each row's key is ``key(machine:tab:)``.
    public static func items(in workspaces: [(WorkspaceModel, machine: String)]) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        for (workspace, machine) in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let attention = tab.attention else { continue }
                        let tabKey = key(machine: machine, tab: tab.id, atMs: attention.atMs)
                        guard !tabKey.isEmpty else { continue }
                        items.append(AgentPaneAttentionTabs.Item(
                            tabId: tabKey, reason: attention.reason, workspaceTitle: workspace.displayName,
                            tabTitle: tab.displayTitle, atMs: attention.atMs))
                    }
                }
            }
        }
        return items.sorted { $0.atMs > $1.atMs }
    }

    /// A bounded opaque key for one request on one tab. Hashing both identities keeps even
    /// unusually long daemon IDs within the bridge's byte bound without truncating identity.
    public static func key(machine: String, tab: String, atMs: UInt64 = 0) -> String {
        "\(digest(machine))/\(digest(tab))/\(atMs)"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves a row against the live store, including its generation. Even before the watch
    /// publishes a clear or replacement, a stale row cannot open that tab's new request.
    public static func locate<Daemon>(_ key: String, in daemons: [Daemon],
                                      machine: (Daemon) -> String, store: (Daemon) -> DaemonStore,
                                      expectedAtMs: UInt64? = nil) -> (daemon: Daemon, tab: String)? {
        guard key.utf8.count <= AgentPaneAttentionTabs.maximumTabID else { return nil }
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let atMs = UInt64(parts[2]), expectedAtMs == nil || expectedAtMs == atMs,
              let daemon = daemons.first(where: { digest(machine($0)) == parts[0] }) else { return nil }
        for workspace in store(daemon).workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { digest($0.id) == parts[1] && $0.attention?.atMs == atMs }) {
                        return (daemon, tab.id)
                    }
                }
            }
        }
        return nil
    }
}
