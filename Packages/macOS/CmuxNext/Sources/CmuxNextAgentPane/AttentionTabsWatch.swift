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
    /// The observation loop. ``AppServices/attentionTabsWatch`` owns this watch; letting it go
    /// (or the services going) cancels the loop, which ends the stream.
    private let task: Task<Void, Never>

    /// Follows the composition root's workspace projection and publishes changed lists.
    public init(workspaces: @escaping @MainActor () -> [(WorkspaceModel, machine: String)],
                publish: @escaping @MainActor ([AgentPaneAttentionTabs.Item]) -> Void) {
        // task-owner: the application retains this watch; deinit cancels the stream
        task = Task {
            for await marked in ObservationStream({ Self.items(in: workspaces()) }) {
                publish(marked)
            }
        }
    }

    // cx-t7hu: nonisolated; the task is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { task.cancel() }

    /// The marked tabs of `workspaces` (each with the id of the machine that holds it), newest
    /// mark first: the agent's reason, the workspace and tab titles the person knows them by (never
    /// an id), and when it was marked. Each row's key is ``key(machine:tab:atMs:)``.
    public static func items(in workspaces: [(WorkspaceModel, machine: String)]) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        for (workspace, machine) in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let attention = tab.attention else { continue }
                        items.append(AgentPaneAttentionTabs.Item(
                            tabId: key(machine: machine, tab: tab.resourceID?.rawValue ?? tab.id, atMs: attention.atMs), reason: attention.reason, workspaceTitle: workspace.displayName,
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
    public static func key(machine: String, tab: String, atMs: UInt64) -> String { "\(machineDigest(machine))/\(atMs)/\(tab)" }

    /// The first 8 bytes of SHA-256 of `machine`, in hex.
    public static func machineDigest(_ machine: String) -> String {
        SHA256.hash(data: Data(machine.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The machine (of `daemons`) and tab id that row key `key` names; nil for a key that names
    /// no connected machine.
    public static func locate<Daemon>(_ key: String, in daemons: [Daemon], machineID: (Daemon) -> String) -> (daemon: Daemon, tab: String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, UInt64(parts[1]) != nil else { return nil }
        let digest = parts[0], tab = String(parts[2])
        guard !tab.isEmpty, let daemon = daemons.first(where: { machineDigest(machineID($0)) == digest }) else { return nil }
        return (daemon, tab)
    }
}
