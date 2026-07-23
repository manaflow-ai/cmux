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
    /// The resolver plan this indicator was painted from. The drop commits
    /// THIS plan, not a re-resolution at release time: the pointer can drift
    /// after the last drag update, and an autoscroll tick can land before
    /// the coalesced repaint, so re-resolving could commit a different gap
    /// than the line the user released on.
    let plan: SidebarWorkspaceReorderDropPlan?
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
    /// The trailing UUID is the drag pasteboard's workspace id, used to
    /// re-arm drag state that was cleared while the native session stayed
    /// alive (app-resign failsafe mid-drag).
    let updateWorkspaceDrag: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> SidebarWorkspaceTableReorderDropUpdate?
    let performWorkspaceDrop: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> Bool
    /// Commits a previously resolved plan verbatim (what the indicator showed).
    let commitWorkspaceDropPlan: (SidebarWorkspaceReorderDropPlan) -> Bool
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
