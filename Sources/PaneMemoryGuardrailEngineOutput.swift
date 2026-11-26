import Foundation

struct PaneMemoryGuardrailEngineOutput: Equatable {
    /// Panes that crossed the threshold this tick and whose banners have not
    /// been dismissed — present each once (edge-trigger).
    var bannersToPresent: [PaneMemoryWarning]
    /// Workspaces that currently own at least one warned pane (badge set).
    var warnedWorkspaceIds: Set<UUID>
    /// Panes currently in warned state.
    var warnedPaneKeys: Set<PaneMemoryPaneKey>
    /// Panes that dropped below the clear level this tick.
    var clearedPanes: Set<PaneMemoryPaneKey>

    var bannerToPresent: PaneMemoryWarning? { bannersToPresent.first }
}
