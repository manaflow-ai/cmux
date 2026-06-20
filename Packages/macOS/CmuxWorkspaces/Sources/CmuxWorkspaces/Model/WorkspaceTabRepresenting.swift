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

    /// The workspace's focused panel id, or `nil` when it has no focus
    /// (legacy `Workspace.focusedPanelId`). The surface-metadata coordinator
    /// reads it to decide whether a coalesced title update targets the panel
    /// whose title currently fronts the window/process title.
    var focusedPanelId: UUID? { get }

    /// The workspace's per-panel process-reported titles
    /// (legacy `Workspace.panelTitles`). The coordinator reads the focused
    /// panel's entry when re-applying the title on focus change.
    var panelTitles: [UUID: String] { get }

    /// Records a coalesced process-reported `title` for one of the workspace's
    /// panels, returning whether any state changed (legacy
    /// `Workspace.updatePanelTitle(panelId:title:)`). The coordinator forwards a
    /// flushed batch entry through this seam; the workspace owns the panel-title
    /// and (when unmasked) workspace-title mutation.
    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool

    /// Promotes `title` to the workspace's process/window title when no custom
    /// title masks it (legacy `Workspace.applyProcessTitle(_:)`). The coordinator
    /// calls it for the focused panel so the window chrome tracks the live title.
    func applyProcessTitle(_ title: String)

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
