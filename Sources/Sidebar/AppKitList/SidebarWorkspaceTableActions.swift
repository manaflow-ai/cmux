import AppKit
import Bonsplit
import CmuxFoundation
import Foundation

/// Closure bundle routing list-level table input and drag operations to
/// existing sidebar actions. Per-row actions resolve separately through
/// `SidebarWorkspaceListActionResolver`.
@MainActor
struct SidebarWorkspaceTableActions {
    let attachScrollView: (NSScrollView) -> Void
    /// Close with confirmation — the middle-click path, distinct from the
    /// row close button's `SidebarWorkspaceRowActions.closeWorkspace`.
    let closeWorkspace: (UUID) -> Void
    let createWorkspaceAtEnd: () -> Void
    let createEmptyWorkspaceGroup: () -> Void
    let beginWorkspaceDrag: (UUID) -> Void
    let endWorkspaceDrag: () -> Void
    let isValidWorkspaceDrag: () -> Bool
    let updateWorkspaceDrag: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool
    let performWorkspaceDrop: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool
    let clearWorkspaceDropIndicator: () -> Void
    let currentDropIndicator: () -> SidebarDropIndicator?
    let currentDropIndicatorScope: () -> SidebarWorkspaceReorderDropIndicatorScope
    let setWorkspaceDropTargetCollectionActive: (Bool) -> Void
    let canPerformBonsplitAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool
    let moveBonsplitToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let moveBonsplitToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
    let didMoveBonsplitToWorkspace: (UUID) -> Void
    let updateDragAutoscroll: () -> Void
    let setBonsplitDropTargetCollectionActive: (Bool) -> Void
    let setBonsplitDropIndicator: (SidebarDropIndicator?) -> Void
}
