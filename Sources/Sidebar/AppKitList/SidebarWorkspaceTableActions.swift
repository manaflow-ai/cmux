import Bonsplit
import AppKit
import CmuxFoundation
import Foundation

/// Closure bundle routing table input and drag operations to existing sidebar actions.
@MainActor
struct SidebarWorkspaceTableActions {
    let attachScrollView: (NSScrollView) -> Void
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
