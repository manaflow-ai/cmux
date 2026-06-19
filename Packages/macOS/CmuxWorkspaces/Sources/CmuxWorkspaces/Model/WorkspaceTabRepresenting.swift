public import Foundation

/// The per-window workspace ("tab") seam `WorkspacesModel` and the workspace
/// coordinators operate through. The app target's `Workspace` god object is
/// the single conformer; the model stores conformers by reference and the
/// group/reorder logic reads exactly the identity, group-membership, and
/// pin state it needs — nothing else of the god object crosses the module
/// boundary.
///
/// Reference semantics are required: group membership (`groupId`) and pin
/// state are mutated in place on the live workspace object, exactly like the
/// legacy in-class code did.
@MainActor
public protocol WorkspaceTabRepresenting: AnyObject, Identifiable where ID == UUID {
    /// The workspace's stable identity.
    var id: UUID { get }
    /// The owning `WorkspaceGroup.id`, or `nil` when ungrouped.
    var groupId: UUID? { get set }
    /// Whether the workspace is pinned (pinned rows float above unpinned).
    var isPinned: Bool { get set }
    /// The workspace's current working directory (group creation inherits
    /// the anchor's / first child's cwd from this).
    var currentDirectory: String { get }
    /// The workspace's display title (the window-title source for the
    /// selected workspace; legacy `Workspace.title`).
    var title: String { get }

    /// Records the shell-activity state for one of the workspace's surfaces
    /// (legacy `Workspace.updatePanelShellActivityState(panelId:state:)`).
    ///
    /// The workspace is the single owner of its per-panel shell-activity
    /// registry and the restored-agent resume bookkeeping a state change
    /// drives; the surface-metadata coordinator reaches that owned mutation
    /// through this seam without the panel registry crossing the module
    /// boundary.
    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState)

    /// Sets (or clears, when `nil`) the workspace's custom tab color override
    /// (legacy `Workspace.setCustomColor(_:)`).
    ///
    /// The hex is already palette-resolved app-side; the reorder coordinator
    /// owns the multi-workspace apply plan (which rows receive the color) and
    /// reaches the live workspace's owned color mutation through this seam.
    func setCustomColor(_ hex: String?)
}
