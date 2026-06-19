public import Foundation

/// Per-window coordinator for the surface-metadata reads and mutations the
/// legacy `TabManager` exposed as backwards-compatibility forwarders over its
/// workspace list: the selected-workspace window title and the per-surface
/// shell-activity state.
///
/// These operate on the window's workspace ("tab") list — owned by
/// ``WorkspacesModel`` — not on any one workspace, so they live here as a
/// coordinator over the list rather than on a single ``WorkspaceTabRepresenting``.
/// The coordinator holds the model by reference (the window owns both and wires
/// them at construction) and reaches each workspace's owned title and
/// shell-activity registry through the ``WorkspaceTabRepresenting`` seam.
///
/// Directory / git-branch / PR-command-hint updates are deliberately **not**
/// here: those project onto the sidebar-git subsystem (CmuxSidebarGit), which
/// the window forwards to directly through its `SidebarGitMetadataServing` /
/// `PullRequestProbing` seams. This coordinator owns only the workspace-list
/// half of the legacy "Surface Directory Updates" section.
@MainActor
public final class SurfaceMetadataCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>

    /// Creates the coordinator over the window's workspace-list model. The
    /// window constructs one instance and holds it; nothing re-instantiates it
    /// per call.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// The title of the workspace with `tabId`, or `nil` when no workspace in
    /// the list has that id (legacy `TabManager.titleForTab(_:)`).
    public func titleForTab(_ tabId: UUID) -> String? {
        model.tabs.first(where: { $0.id == tabId })?.title
    }

    /// Records `state` as the shell-activity state for surface `surfaceId` in
    /// workspace `tabId`, mutating the owning workspace's registry through the
    /// ``WorkspaceTabRepresenting`` seam (legacy
    /// `TabManager.updateSurfaceShellActivity(tabId:surfaceId:state:)`, minus
    /// the pull-request refresh).
    ///
    /// Returns `true` exactly when the legacy method would schedule a
    /// pull-request refresh: the workspace exists **and** `state` is
    /// `.promptIdle`. The window performs that refresh through its
    /// `PullRequestProbing` seam, which this package does not import; the
    /// decision is surfaced here so the window-side seam call stays a thin
    /// conditional forward with no logic of its own.
    @discardableResult
    public func applySurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: PanelShellActivityState
    ) -> Bool {
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return false }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        return state == .promptIdle
    }
}
