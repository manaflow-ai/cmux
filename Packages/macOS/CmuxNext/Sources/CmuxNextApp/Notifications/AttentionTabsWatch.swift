import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CryptoKit
import Foundation

/// Keeps ``AgentPaneAttentionTabs`` (every agent page's Needs you list) and the palette's Go to
/// What Needs Me on the tabs an agent marked (`tab-attention-v1`, `cmux attention request`), on
/// every connected machine. Observes the store reads ``items(in:)`` makes, re-armed after each
/// change; nothing polls. Only a marked tab's titles are read, so a title change of any other tab
/// wakes nothing.
@MainActor
final class AttentionTabsWatch {
    /// The observation loop. ``AppServices/attentionTabsWatch`` owns this watch; letting it go
    /// (or the services going) cancels the loop, which ends the stream.
    private let task: Task<Void, Never>

    /// Starts the watch. Go to's jump is bound with the action (``AttentionPalettePage/bind(into:context:)``).
    init(_ services: AppServices) {
        // task-owner: AppServices.attentionTabsWatch; cancelled in deinit, and it returns once the services are gone
        task = Task { [weak services] in
            for await marked in ObservationStream({ [weak services] in
                services.map { AttentionTabsWatch.items(in: $0.machines.allWorkspaces.map { ($0.0, machine: $0.1.machineID) }) } ?? []
            }) {
                guard services != nil else { return }
                AgentPaneAttentionTabs.shared.items = marked
                services?.notifications.attentionMarksChanged(marked)
            }
        }
    }

    // cx-t7hu: nonisolated; the task is a Sendable let, so cancelling needs no main-actor hop.
    nonisolated deinit { task.cancel() }

    /// The marked tabs of `workspaces` (each with the id of the machine that holds it), newest
    /// mark first: the agent's reason, the workspace and tab titles the person knows them by (never
    /// an id), and when it was marked. Each row's key is ``key(machine:tab:)``.
    static func items(in workspaces: [(WorkspaceModel, machine: String)]) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        for (workspace, machine) in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let attention = tab.attention else { continue }
                        let tabKey = key(machine: machine, tab: tab.id)
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

    /// A marked tab's row key (`Item.tabId`, what a page's Go to sends back): a short digest of
    /// its machine's id, `/`, and its tab id, since tabs on two machines can share an id. The
    /// digest keeps the key inside ``AgentPaneAttentionTabs/maximumTabID`` however long the
    /// machine id is, and a tab id holds no `/`.
    static func key(machine: String, tab: String) -> String {
        let key = "\(machineDigest(machine))/\(tab)"
        return key.utf8.count <= AgentPaneAttentionTabs.maximumTabID ? key : ""
    }

    /// The first 8 bytes of SHA-256 of `machine`, in hex.
    static func machineDigest(_ machine: String) -> String {
        SHA256.hash(data: Data(machine.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The machine (of `daemons`) and tab id that row key `key` names; nil for a key that names
    /// no connected machine.
    static func locate(_ key: String, in daemons: [DaemonService], expectedAtMs: UInt64? = nil)
        -> (daemon: DaemonService, tab: String)? {
        guard let slash = key.lastIndex(of: "/") else { return nil }
        let digest = key[..<slash], tab = String(key[key.index(after: slash)...])
        guard key.utf8.count <= AgentPaneAttentionTabs.maximumTabID, !tab.isEmpty,
              let daemon = daemons.first(where: { machineDigest($0.machineID) == digest }) else { return nil }
        if let expectedAtMs,
           daemon.store.tab(idOrResource: tab)?.attention?.atMs != expectedAtMs { return nil }
        return (daemon, tab)
    }
}
