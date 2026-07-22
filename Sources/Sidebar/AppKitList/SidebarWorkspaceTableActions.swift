import Bonsplit
import AppKit
import CmuxFoundation
import Foundation

/// Accepted reorder plan for the pointer's current position. The AppKit table
/// keeps this out of the SwiftUI drag state on purpose: writing the indicator
/// there rebuilds every sidebar row per gap change, which is what made the
/// painted line visibly lag the pointer on large sidebars.
struct SidebarWorkspaceTableReorderDropUpdate {
    let indicator: SidebarDropIndicator?
    let scope: SidebarWorkspaceReorderDropIndicatorScope
    let draggedWorkspaceId: UUID
    /// Scope-filtered ids for the indicator predicate, in display order.
    let indicatorRowIds: [UUID]
}

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
    let updateWorkspaceDrag: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> SidebarWorkspaceTableReorderDropUpdate?
    let performWorkspaceDrop: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool
    let clearWorkspaceDropIndicator: () -> Void
    let currentDropIndicator: () -> SidebarDropIndicator?
    let currentDropIndicatorScope: () -> SidebarWorkspaceReorderDropIndicatorScope
    let canPerformBonsplitAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool
    let moveBonsplitToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let moveBonsplitToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
    let didMoveBonsplitToWorkspace: (UUID) -> Void
    let updateDragAutoscroll: () -> Void
    let setBonsplitDropTargetCollectionActive: (Bool) -> Void
    let setBonsplitDropIndicator: (SidebarDropIndicator?) -> Void
}
