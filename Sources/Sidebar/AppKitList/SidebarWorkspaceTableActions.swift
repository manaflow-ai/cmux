import Bonsplit
import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation

/// Native source identity and completion callbacks carried as one capability.
typealias SidebarWorkspaceTableNativeDragLifecycle = (
    currentSessionId: () -> UUID?,
    finish: (UUID, String) -> Void,
    reclaimSupersededNativeSources: () -> Void
)

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
    /// Native session capability owned by the AppKit source.
    ///
    /// Keeping the identity reader and terminal callback together prevents a
    /// partially wired action bundle from falling back to unscoped cleanup.
    typealias NativeWorkspaceDragLifecycle = SidebarWorkspaceTableNativeDragLifecycle

    let attachScrollView: (NSScrollView) -> Void
    let closeWorkspace: (UUID) -> Void
    let createWorkspaceAtEnd: () -> Void
    let createEmptyWorkspaceGroup: () -> Void
    let beginWorkspaceDrag: (UUID) -> Void
    let movingWorkspaceCount: ((UUID) -> Int)?
    let endWorkspaceDrag: () -> Void
    let isValidWorkspaceDrag: () -> Bool
    /// The trailing UUID is the drag pasteboard's workspace id, used to
    /// restore presentation while the native session stays alive.
    let updateWorkspaceDrag: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> SidebarWorkspaceTableReorderDropUpdate?
    let performWorkspaceDrop: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> Bool
    /// Commits a drop accepted before the target snapshot arrived and the
    /// native source completed.
    let performPendingWorkspaceDrop: ((SidebarWorkspaceReorderPendingDrop, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
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
    /// Resolves the identity represented by a rendered row. Empty group
    /// headers use the durable group id; grouped members keep their workspace
    /// id so member drags never accidentally move the anchor.
    let workspaceIdForDrag: ((SidebarWorkspaceRenderItemID, UUID) -> UUID)?
    /// Native source ownership, when this bundle supports tokenized completion.
    let nativeWorkspaceDragLifecycle: NativeWorkspaceDragLifecycle?

    init(
        attachScrollView: @escaping (NSScrollView) -> Void,
        closeWorkspace: @escaping (UUID) -> Void,
        createWorkspaceAtEnd: @escaping () -> Void,
        createEmptyWorkspaceGroup: @escaping () -> Void,
        beginWorkspaceDrag: @escaping (UUID) -> Void,
        movingWorkspaceCount: ((UUID) -> Int)?,
        endWorkspaceDrag: @escaping () -> Void,
        isValidWorkspaceDrag: @escaping () -> Bool,
        updateWorkspaceDrag: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> SidebarWorkspaceTableReorderDropUpdate?,
        performWorkspaceDrop: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID?) -> Bool,
        performPendingWorkspaceDrop: ((SidebarWorkspaceReorderPendingDrop, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)? = nil,
        commitWorkspaceDropPlan: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool,
        clearWorkspaceDropIndicator: @escaping () -> Void,
        currentDropIndicator: @escaping () -> SidebarDropIndicator?,
        currentDropIndicatorScope: @escaping () -> SidebarWorkspaceReorderDropIndicatorScope,
        canPerformBonsplitAction: @escaping (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool,
        moveBonsplitToExistingWorkspace: @escaping (UUID, BonsplitTabDragPayload.Transfer) -> Bool,
        moveBonsplitToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID?,
        didMoveBonsplitToWorkspace: @escaping (UUID) -> Void,
        updateDragAutoscroll: @escaping () -> Void,
        setBonsplitDropTargetCollectionActive: @escaping (Bool) -> Void,
        setBonsplitDropIndicator: @escaping (SidebarDropIndicator?) -> Void,
        workspaceIdForDrag: ((SidebarWorkspaceRenderItemID, UUID) -> UUID)? = nil,
        nativeWorkspaceDragLifecycle: NativeWorkspaceDragLifecycle? = nil
    ) {
        self.attachScrollView = attachScrollView
        self.closeWorkspace = closeWorkspace
        self.createWorkspaceAtEnd = createWorkspaceAtEnd
        self.createEmptyWorkspaceGroup = createEmptyWorkspaceGroup
        self.beginWorkspaceDrag = beginWorkspaceDrag
        self.movingWorkspaceCount = movingWorkspaceCount
        self.endWorkspaceDrag = endWorkspaceDrag
        self.isValidWorkspaceDrag = isValidWorkspaceDrag
        self.updateWorkspaceDrag = updateWorkspaceDrag
        self.performWorkspaceDrop = performWorkspaceDrop
        self.performPendingWorkspaceDrop = performPendingWorkspaceDrop
        self.commitWorkspaceDropPlan = commitWorkspaceDropPlan
        self.clearWorkspaceDropIndicator = clearWorkspaceDropIndicator
        self.currentDropIndicator = currentDropIndicator
        self.currentDropIndicatorScope = currentDropIndicatorScope
        self.canPerformBonsplitAction = canPerformBonsplitAction
        self.moveBonsplitToExistingWorkspace = moveBonsplitToExistingWorkspace
        self.moveBonsplitToNewWorkspace = moveBonsplitToNewWorkspace
        self.didMoveBonsplitToWorkspace = didMoveBonsplitToWorkspace
        self.updateDragAutoscroll = updateDragAutoscroll
        self.setBonsplitDropTargetCollectionActive = setBonsplitDropTargetCollectionActive
        self.setBonsplitDropIndicator = setBonsplitDropIndicator
        self.workspaceIdForDrag = workspaceIdForDrag
        self.nativeWorkspaceDragLifecycle = nativeWorkspaceDragLifecycle
    }
}
