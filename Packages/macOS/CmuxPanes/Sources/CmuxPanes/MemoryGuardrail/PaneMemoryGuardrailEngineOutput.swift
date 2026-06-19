public import Foundation

/// The decision the engine reaches for one scan tick: which banners to present,
/// which workspaces own a warned pane, the full warned set, and what cleared.
public struct PaneMemoryGuardrailEngineOutput: Equatable {
    /// Panes that crossed the threshold this tick and whose banners have not
    /// been dismissed — present each once (edge-trigger).
    public var bannersToPresent: [PaneMemoryWarning]
    /// Workspaces that currently own at least one warned pane (badge set).
    public var warnedWorkspaceIds: Set<UUID>
    /// Panes currently in warned state.
    public var warnedPaneKeys: Set<PaneMemoryPaneKey>
    /// Panes that dropped below the clear level this tick.
    public var clearedPanes: Set<PaneMemoryPaneKey>

    public init(
        bannersToPresent: [PaneMemoryWarning],
        warnedWorkspaceIds: Set<UUID>,
        warnedPaneKeys: Set<PaneMemoryPaneKey>,
        clearedPanes: Set<PaneMemoryPaneKey>
    ) {
        self.bannersToPresent = bannersToPresent
        self.warnedWorkspaceIds = warnedWorkspaceIds
        self.warnedPaneKeys = warnedPaneKeys
        self.clearedPanes = clearedPanes
    }

    public var bannerToPresent: PaneMemoryWarning? { bannersToPresent.first }
}
