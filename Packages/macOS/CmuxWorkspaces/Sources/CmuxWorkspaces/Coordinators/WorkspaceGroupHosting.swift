public import Foundation
public import CmuxSettings

/// The window-side seam `WorkspaceGroupCoordinator` drives for the effects
/// it cannot own: workspace creation/teardown (the `Workspace` god object
/// still lives in the app target), selection moves, sidebar multi-selection
/// sync, localized strings, settings reads, and window-chrome refreshes.
/// The per-window `TabManager` is the single implementer.
///
/// Synchronous two-way protocol for the same reason as `WorkspacesHosting`:
/// every legacy group operation is one MainActor turn interleaving reads
/// and writes (creating the anchor re-enters the model through the tabs
/// willSet, selecting a workspace re-enters through the selection didSet).
@MainActor
public protocol WorkspaceGroupHosting<Tab>: WorkspaceOrderHosting {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    // MARK: Workspace lifecycle (stays with the Workspace god object)

    /// Creates the fresh anchor workspace for a new group (legacy
    /// `addWorkspace(title:workingDirectory:inheritWorkingDirectory:select:
    /// placementOverride: .top, autoWelcomeIfNeeded: false,
    /// normalizeWorkspaceGroupsAfterInsert: false)`).
    func createGroupAnchorWorkspace(
        title: String,
        workingDirectory: String?,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Tab
    /// Creates a member workspace for `createWorkspaceInGroup` (legacy
    /// `addWorkspace(workingDirectory:initialSurface:inheritWorkingDirectory:
    /// select:autoWelcomeIfNeeded: false)`).
    func createWorkspaceForGroup(
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Tab
    /// Closes a member workspace during group deletion (legacy
    /// `closeWorkspace(_:recordHistory:)`, including its teardown chain).
    func closeWorkspaceForGroupDeletion(_ tab: Tab, recordHistory: Bool)
    /// Selects the workspace through the legacy selection entry point
    /// (DEBUG switch tracing + dismissal context ride along).
    func selectWorkspace(_ tab: Tab)

    // MARK: Sidebar multi-selection sync (CmuxSidebar model, owned app-side)

    /// The current sidebar multi-selection.
    var sidebarSelectedWorkspaceIds: Set<UUID> { get }
    /// Collapses the sidebar multi-selection onto the fresh group anchor
    /// (legacy `replaceSelection(with: [anchorId])` +
    /// `postDidHide(hiddenWorkspaceIds:focusedWorkspaceId: anchorId)`).
    func collapseSidebarSelectionForGroupCreation(
        hiddenWorkspaceIds: Set<UUID>,
        anchorId: UUID
    )
    /// Strips now-hidden members from the sidebar multi-selection on group
    /// collapse (legacy `subtractSelection(_:)` +
    /// `postDidHide(hiddenWorkspaceIds:focusedWorkspaceId:)`).
    func subtractSidebarSelection(
        hiddenWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?
    )

    // MARK: App-side values

    /// Localized `"Group %lld"` format for auto-generated group names
    /// (String(localized:) stays app-side).
    var localizedAutoGroupNameFormat: String { get }
    /// The stored global default placement for new in-group workspaces
    /// (legacy settings read of `workspaceGroups.newWorkspacePlacement`).
    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement { get }
    /// Normalizes a group icon SF Symbol name (legacy
    /// `RenderableSystemSymbol.normalized(_:)`, app-side catalog).
    func normalizedGroupIconSymbol(_ symbol: String?) -> String?
    /// A group was renamed: refresh window chrome and post the legacy
    /// `workspaceGroupNameDidChange` notification.
    func workspaceGroupNameDidChange()
}
