public import Foundation

/// Resolves the per-window panel/surface identifiers the legacy `TabManager`
/// god object looked up inline: a workspace's focused panel id, and the panel
/// id that owns an incoming id which may be either a panel id or a bonsplit
/// surface id.
///
/// It owns no state. It reads the window's ``WorkspacesModel`` tab order and,
/// for surface-to-panel mapping, the per-workspace panel-registry / surface-map
/// reads exposed by ``WorkspaceTabRepresenting``. Because the resolution is the
/// same pure lookup the legacy computed accessors performed, this is a real
/// instance (constructor-injected with the model) rather than a static-only
/// namespace: the model it reads is its injected dependency.
///
/// `@MainActor` because the workspace list and the live bonsplit surface map it
/// reads through are main-actor state, and every caller (focus restore,
/// notification routing, control-socket surface resolution) is already on the
/// main actor. The reads are synchronous, mirroring the legacy optional-chained
/// `tabs.first(where:)` / `panels[...]` lookups one-for-one; a gone workspace
/// or surface yields `nil`, exactly as before.
@MainActor
public final class PanelIdResolver<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>

    /// Creates the resolver over the window's workspace-list model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// The focused panel id for the workspace, or `nil` when the workspace is
    /// gone or has no focus (legacy `TabManager.focusedPanelId(for:)`:
    /// `tabs.first(where: { $0.id == tabId })?.focusedPanelId`).
    public func focusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID? {
        model.tabs.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    /// Resolves `surfaceOrPanelId` to a panel id within `workspace`: returns it
    /// unchanged when it is already a live panel id, otherwise maps it as a
    /// surface id through the workspace's surface-to-panel map. Returns `nil`
    /// when it is neither (legacy
    /// `TabManager.panelId(forSurfaceOrPanelId:in workspace:)`).
    public func panelId(forSurfaceOrPanelId surfaceOrPanelId: UUID, in workspace: Tab) -> UUID? {
        if workspace.panelExists(surfaceOrPanelId) {
            return surfaceOrPanelId
        }
        return workspace.panelId(forSurfaceId: surfaceOrPanelId)
    }

    /// Resolves `surfaceOrPanelId` to a panel id within the workspace identified
    /// by `workspaceId`, or `nil` when the workspace is gone or the id resolves
    /// to no panel (legacy `TabManager`'s `NotificationDismissalHosting`
    /// witness:
    /// `guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }`
    /// then `panelId(forSurfaceOrPanelId:in: workspace)`).
    public func panelId(forSurfaceOrPanelId surfaceOrPanelId: UUID, inWorkspaceId workspaceId: UUID) -> UUID? {
        guard let workspace = model.tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return panelId(forSurfaceOrPanelId: surfaceOrPanelId, in: workspace)
    }
}
