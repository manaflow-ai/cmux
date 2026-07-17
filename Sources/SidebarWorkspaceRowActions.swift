import AppKit
import CmuxWorkspaces
import Foundation

/// Closure capabilities for a workspace row.
///
/// Actions may capture parent-owned models, but the row can neither retain nor
/// observe those models directly. This makes the lazy-list snapshot boundary a
/// type-level rule instead of a convention at each call site.
@MainActor
struct SidebarWorkspaceRowActions {
    let select: (NSEvent.ModifierFlags) -> Void
    let setCustomTitle: (String) -> Void
    let clearCustomTitle: () -> Void
    let clearCustomDescription: () -> Void
    let editDescription: () -> Void
    let closeWorkspace: () -> Void
    let moveBy: (Int) -> Void
    let moveTargetsToTop: ([UUID]) -> Void
    /// Resolves volatile app-window topology when the deferred menu is presented.
    let currentWindowMoveTargets: () -> [SidebarWorkspaceWindowMoveTarget]
    let moveTargetsToWindow: ([UUID], UUID) -> Void
    let moveTargetsToNewWindow: ([UUID]) -> Void
    let closeTargets: ([UUID], Bool) -> Void
    let closeOtherTargets: ([UUID]) -> Void
    let closeTargetsBelow: () -> Void
    let closeTargetsAbove: () -> Void
    let performPin: () -> Void
    let createEmptyGroup: () -> Void
    let createGroup: ([UUID]) -> Void
    let addTargetsToGroup: ([UUID], UUID) -> Void
    let removeTargetsFromGroup: ([UUID]) -> Void
    let reconnectTargets: ([UUID]) -> Void
    let disconnectTargets: ([UUID]) -> Void
    let applyColor: (String?, [UUID]) -> Void
    let applyTodoStatus: (WorkspaceTaskStatus?, [UUID]) -> Void
    let hideTodoStatus: ([UUID]) -> Void
    let requestChecklistAdd: () -> Void
    let markRead: ([UUID]) -> Void
    let markUnread: ([UUID]) -> Void
    let clearLatestNotifications: ([UUID]) -> Void
    let openNotification: (TerminalNotification) -> Void
    let copyWorkspaceLinks: ([UUID]) -> Void
    let openPullRequest: (URL) -> Void
    let openPort: (Int) -> Void
    let checklist: SidebarWorkspaceChecklistActions
    let onToggleChecklistExpansion: () -> Void
    let onConsumeChecklistAddFieldActivation: () -> Void
    let onChecklistPopoverPresentedChange: (Bool) -> Void
    var onContextMenuAppear: () -> Void
    var onContextMenuDisappear: () -> Void

    /// Returns a copy whose context-menu callbacks also notify the AppKit
    /// table cell, so the controller can pin hover while a row's menu is open.
    func composingContextMenuCallbacks(
        didOpen: @escaping () -> Void,
        didClose: @escaping () -> Void
    ) -> Self {
        var composed = self
        let baseAppear = onContextMenuAppear
        let baseDisappear = onContextMenuDisappear
        composed.onContextMenuAppear = {
            baseAppear()
            didOpen()
        }
        composed.onContextMenuDisappear = {
            baseDisappear()
            didClose()
        }
        return composed
    }
}

/// Binds parent-owned action capabilities to one lazily realized row input.
typealias SidebarWorkspaceRowActionFactory = @MainActor (SidebarWorkspaceRowInput) -> SidebarWorkspaceRowActions
