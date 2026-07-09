public import Foundation

/// The window-side seam ``WorkspaceCommandCoordinator`` drives for the
/// workspace-command effects it cannot own from the package: pin toggling
/// (which routes through the app-target `WorkspaceActionDispatcher` and beeps on
/// failure), the legacy `TabManager` selection/title mutations, NSAlert-backed
/// close-with-confirmation, cross-window move (owned by `AppDelegate`), the
/// notification store's mark-read/unread, the command-palette rename/edit flows,
/// and the localized pin label.
///
/// The per-window app target is the single implementer (the `cmuxApp` menu shell
/// forwards into the coordinator, the coordinator forwards each irreducible
/// effect back through this host). Splitting it this way keeps the index math,
/// tab-list slicing, and menu-enablement logic in the package while the
/// AppKit/`AppDelegate`/`TabManager`/`TerminalNotificationStore` reach stays
/// app-side, exactly where those god types live.
///
/// Synchronous and `@MainActor` for the same reason as the sibling workspace
/// coordinators: every workspace-command effect is one main-actor turn driven by
/// a menu action, so the host lives where its callers live and no bridging is
/// needed.
@MainActor
public protocol WorkspaceCommandHosting: AnyObject {
    // MARK: Pin (app-target WorkspaceActionDispatcher / WorkspacePinCommands)

    /// The localized pin/unpin label for the selected workspace
    /// (`WorkspacePinCommands.selectedWorkspaceMenuLabel`).
    var selectedWorkspacePinToggleLabel: String { get }
    /// Whether a pin toggle is currently possible (legacy `pinState != nil`).
    var selectedWorkspaceCanTogglePin: Bool { get }
    /// Toggles the selected workspace's pin state, beeping on failure exactly as
    /// the legacy helper did (`WorkspacePinCommands.toggleSelectedWorkspace`
    /// returning `false` → `NSSound.beep()`).
    func toggleSelectedWorkspacePin()

    // MARK: Selection / title (legacy TabManager / Workspace)

    /// Whether the selected workspace carries a user-set custom title
    /// (`Workspace.hasCustomTitle`); drives the "Remove Custom Workspace Name"
    /// item's presence. Read through the host because `hasCustomTitle` lives on
    /// the app-target `Workspace` god object, not the `WorkspaceTabRepresenting`
    /// seam.
    var selectedWorkspaceHasCustomTitle: Bool { get }
    /// Clears the selected workspace's custom title
    /// (`TabManager.clearCustomTitle(tabId:)`).
    func clearSelectedWorkspaceCustomName()
    /// Re-selects `workspaceId` after a reorder move through the legacy
    /// `TabManager.selectWorkspace(_ workspace: Workspace)` overload, which routes
    /// to `selectWorkspaceId(_:notificationDismissalContext: .explicitWorkspaceResume)`.
    ///
    /// This is NOT the bare `selectedTabId` setter
    /// (`TabManager+FocusHistoryHosting.selectWorkspace(_:UUID)`). The reorder
    /// re-selection always targets the already-selected workspace (reorder never
    /// touches selection), so the bare setter would be a no-op. The legacy
    /// `.explicitWorkspaceResume` path is NOT a no-op on the equal-id branch: it
    /// still calls `setPendingSelectionContext(nil)` and
    /// `dismissFocusedPanelNotificationIfActive(_:.explicitWorkspaceResume)`,
    /// dismissing the moved workspace's active focused-panel notification and
    /// consuming the focus-flash suppression latch. The distinct name keeps the
    /// conformance from accidentally binding to the no-op UUID overload.
    func resumeWorkspaceSelectionAfterReorder(_ workspaceId: UUID)

    // MARK: Close (NSAlert confirmation, app-target TabManager)

    /// Closes the current workspace through the confirmation flow
    /// (`TabManager.closeCurrentWorkspaceWithConfirmation()`).
    func closeCurrentWorkspaceWithConfirmation()
    /// Closes the given workspaces through the confirmation flow
    /// (`TabManager.closeWorkspacesWithConfirmation(_:allowPinned:)`).
    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool)

    // MARK: Cross-window move (app-target AppDelegate)

    /// The other live windows the selected workspace can move into
    /// (`AppDelegate.windowMoveTargets(referenceWindowId:)` mapped to the
    /// package value type).
    func windowMoveTargets() -> [WorkspaceCommandWindowTarget]
    /// Moves `workspaceId` into the window `windowId`
    /// (`AppDelegate.moveWorkspaceToWindow(workspaceId:windowId:focus:)`).
    func moveWorkspace(_ workspaceId: UUID, toWindow windowId: UUID)
    /// Moves `workspaceId` into a brand-new window
    /// (`AppDelegate.moveWorkspaceToNewWindow(workspaceId:focus:)`).
    func moveWorkspaceToNewWindow(_ workspaceId: UUID)

    // MARK: Notification store (mark read/unread)

    /// Whether the selected workspace can be marked read
    /// (`TerminalNotificationStore.canMarkWorkspaceRead(forTabIds:)`).
    func canMarkWorkspaceRead(_ workspaceId: UUID) -> Bool
    /// Whether the selected workspace can be marked unread
    /// (`TerminalNotificationStore.canMarkWorkspaceUnread(forTabIds:)`).
    func canMarkWorkspaceUnread(_ workspaceId: UUID) -> Bool
    /// Marks the workspace read (`TerminalNotificationStore.markRead(forTabId:)`).
    func markWorkspaceRead(_ workspaceId: UUID)
    /// Marks the workspace unread
    /// (`TerminalNotificationStore.markUnread(forTabId:)`).
    func markWorkspaceUnread(_ workspaceId: UUID)

    // MARK: Command palette (app-target AppDelegate)

    /// Opens the rename-workspace command-palette flow
    /// (`AppDelegate.requestRenameWorkspaceViaCommandPalette()`).
    func requestRenameSelectedWorkspace()
    /// Opens the edit-description command-palette flow
    /// (`AppDelegate.requestEditWorkspaceDescriptionViaCommandPalette()`).
    func requestEditSelectedWorkspaceDescription()
}
