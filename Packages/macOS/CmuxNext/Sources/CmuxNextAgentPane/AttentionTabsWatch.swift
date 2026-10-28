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

    /// Starts one observation stream; nil workspaces means its composition-root owner is gone.
    public init(tabs: AgentPaneAttentionTabs,
                workspaces: @escaping @MainActor () -> [(WorkspaceModel, machine: String)]?,
                onChange: @escaping @MainActor ([AgentPaneAttentionTabs.Item]) -> Void) {
        // task-owner: AppServices.attentionTabsWatch; cancelled in deinit, or when workspaces returns nil
        task = Task {
            for await marked in ObservationStream({ workspaces().map(Self.items(in:)) }) {
                guard let marked else { return }
                tabs.items = marked
                onChange(marked)
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
