import AppKit
import CmuxWorkspaces
import Foundation

/// `TabManager`'s conformance to the `CmuxWorkspaces` `WorkspaceCommandHosting`
/// seam: the irreducible app-coupled effects behind the workspace-command menu
/// that the package `WorkspaceCommandCoordinator` cannot own.
///
/// The coordinator keeps the selected-workspace index math, the move/close
/// tab-list slicing, and the menu-item enablement; this conformance performs the
/// pin toggle (through the app-target `WorkspacePinCommands` /
/// `WorkspaceActionDispatcher`, beeping on failure), the legacy `TabManager`
/// selection/title mutations, the NSAlert close-confirmation flow, the
/// cross-window move (owned by `AppDelegate`), the notification-store
/// mark-read/unread, and the command-palette rename/edit requests. These are the
/// exact bodies the `cmuxApp` private helpers used to inline; they live here
/// because `AppDelegate`, `TabManager`, and `TerminalNotificationStore` are all
/// app-target god types.
extension TabManager: WorkspaceCommandHosting {
    // MARK: Pin

    var selectedWorkspacePinToggleLabel: String {
        WorkspacePinCommands.selectedWorkspaceMenuLabel(in: self)
    }

    var selectedWorkspaceCanTogglePin: Bool {
        WorkspacePinCommands.selectedWorkspacePinState(in: self) != nil
    }

    func toggleSelectedWorkspacePin() {
        if !WorkspacePinCommands.toggleSelectedWorkspace(in: self) {
            NSSound.beep()
        }
    }

    // MARK: Selection / title

    var selectedWorkspaceHasCustomTitle: Bool {
        selectedWorkspace?.hasCustomTitle == true
    }

    func clearSelectedWorkspaceCustomName() {
        guard let workspace = selectedWorkspace else { return }
        clearCustomTitle(tabId: workspace.id)
    }

    // The post-reorder re-selection MUST route through the legacy
    // `selectWorkspace(_ workspace: Workspace)` overload (not the bare
    // `selectWorkspace(_:UUID)` setter in `TabManager+FocusHistoryHosting`). That
    // overload runs `selectWorkspaceId(_:notificationDismissalContext:
    // .explicitWorkspaceResume)`, whose equal-id early-return branch still fires
    // `setPendingSelectionContext(nil)` and dismisses the moved workspace's active
    // focused-panel notification (consuming the focus-flash suppression latch).
    // Because reorder never changes `selectedTabId`, the bare setter would be a
    // no-op and silently drop that dismissal — the regression this method exists
    // to prevent. When the id has no live tab (invariant violation), this is a
    // no-op, matching the legacy `manager.selectedWorkspace` guard at the call
    // site.
    func resumeWorkspaceSelectionAfterReorder(_ workspaceId: UUID) {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return }
        selectWorkspace(workspace)
    }

    // `closeCurrentWorkspaceWithConfirmation()` and
    // `closeWorkspacesWithConfirmation(_:allowPinned:)` are likewise existing
    // `TabManager` methods (the NSAlert close-confirmation flow) and satisfy the
    // close requirements directly — they are not redeclared here to avoid
    // self-recursion.

    // MARK: Cross-window move

    func windowMoveTargets() -> [WorkspaceCommandWindowTarget] {
        let referenceWindowId = AppDelegate.shared?.windowId(for: self)
        let targets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        return targets.map {
            WorkspaceCommandWindowTarget(
                windowId: $0.windowId,
                label: $0.label,
                isCurrentWindow: $0.isCurrentWindow
            )
        }
    }

    func moveWorkspace(_ workspaceId: UUID, toWindow windowId: UUID) {
        _ = AppDelegate.shared?.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: true)
    }

    func moveWorkspaceToNewWindow(_ workspaceId: UUID) {
        _ = AppDelegate.shared?.moveWorkspaceToNewWindow(workspaceId: workspaceId, focus: true)
    }

    // MARK: Notification store

    func canMarkWorkspaceRead(_ workspaceId: UUID) -> Bool {
        TerminalNotificationStore.shared.canMarkWorkspaceRead(forTabIds: [workspaceId])
    }

    func canMarkWorkspaceUnread(_ workspaceId: UUID) -> Bool {
        TerminalNotificationStore.shared.canMarkWorkspaceUnread(forTabIds: [workspaceId])
    }

    func markWorkspaceRead(_ workspaceId: UUID) {
        TerminalNotificationStore.shared.markRead(forTabId: workspaceId)
    }

    func markWorkspaceUnread(_ workspaceId: UUID) {
        TerminalNotificationStore.shared.markUnread(forTabId: workspaceId)
    }

    // MARK: Command palette

    func requestRenameSelectedWorkspace() {
        _ = AppDelegate.shared?.requestRenameWorkspaceViaCommandPalette()
    }

    func requestEditSelectedWorkspaceDescription() {
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }
}
