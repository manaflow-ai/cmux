import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
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
                services.map { AttentionTabsWatch.items(in: $0.machines.allWorkspaces.map(\.0)) } ?? []
            }) {
                guard services != nil else { return }
                AgentPaneAttentionTabs.shared.items = marked
            }
        }
    }

    deinit { task.cancel() }

    /// The marked tabs of `workspaces`, newest mark first: the agent's reason, the workspace and
    /// tab titles the person knows them by (never an id), and when it was marked.
    static func items(in workspaces: [WorkspaceModel]) -> [AgentPaneAttentionTabs.Item] {
        var items: [AgentPaneAttentionTabs.Item] = []
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        guard let attention = tab.attention else { continue }
                        items.append(AgentPaneAttentionTabs.Item(
                            tabId: tab.id, reason: attention.reason, workspaceTitle: workspace.displayName,
                            tabTitle: tab.displayTitle, atMs: attention.atMs))
                    }
                }
            }
        }
        return items.sorted { $0.atMs > $1.atMs }
    }
}
