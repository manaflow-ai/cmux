import AppKit
import SwiftUI

/// How a sidebar workspace row / group header is being rendered.
enum SidebarWorkspaceRowRenderRole {
    /// A normal interactive row in the list. Carries the reorder gesture and
    /// reports its frame; renders invisible while it is the one being dragged
    /// (its visible copy is the floating follower).
    case list
    /// The floating follower copy painted over the list during a reorder drag.
    /// Always fully visible, never interactive, reports no frame.
    case dragFollower
}

/// Gesture-driven workspace reorder, shared by workspace rows and group-header
/// (anchor) rows so both reorder through one path. Replaces the old
/// `.onDrag` system-drag + `DropDelegate` reorder, whose coarse, target-gated
/// location updates made the drag feel laggy.
extension VerticalTabsSidebar {
    /// The spring the list rows use to animate the gap open and to settle into
    /// place on drop.
    static let sidebarReorderAnimation = Animation.snappy(duration: 0.22, extraBounce: 0.02)

    /// Handles a reorder drag tick: begins the drag on the first event, then
    /// updates the follower position and landing slot.
    ///
    /// - Parameters:
    ///   - draggedId: the workspace (or group anchor) being dragged.
    ///   - startLocationY: the gesture's start Y in the reorder list space.
    ///   - cursorY: the gesture's current Y in the reorder list space.
    func sidebarReorderGestureChanged(
        draggedId: UUID,
        startLocationY: CGFloat,
        cursorY: CGFloat,
        renderContext: WorkspaceListRenderContext
    ) {
        // Escape cancelled this drag mid-gesture. The DragGesture itself stays
        // alive until the mouse releases and keeps streaming onChanged; without
        // this latch the next event would re-begin the cancelled drag.
        guard dragState.cancelledReorderTabId != draggedId else { return }
        if dragState.draggedTabId != draggedId {
            #if DEBUG
            cmuxDebugLog("sidebar.reorder.begin id=\(draggedId.uuidString.prefix(5)) startY=\(Int(startLocationY)) cursorY=\(Int(cursorY))")
            #endif
            let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedId,
                targetWorkspaceId: nil
            )
            let reorderIds = tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedId,
                usesTopLevelRows: usesTopLevelRows
            )
            let pinnedIds = tabManager.sidebarReorderPinnedWorkspaceIds(
                forDraggedWorkspaceId: draggedId,
                usesTopLevelRows: usesTopLevelRows
            )
            let composition = sidebarReorderScopeBandComposition(
                usesTopLevelRows: usesTopLevelRows,
                renderContext: renderContext
            )
            let frame = dragState.rowFramesInList[draggedId]
            let grabOffsetY = frame.map { startLocationY - $0.minY } ?? 0
            dragState.beginReorder(
                tabId: draggedId,
                usesTopLevelRows: usesTopLevelRows,
                reorderIds: reorderIds,
                pinnedIds: pinnedIds,
                scopeBandComposition: composition,
                draggedRowFrame: frame,
                grabOffsetY: grabOffsetY,
                cursorY: cursorY
            )
        } else {
            dragState.updateReorder(cursorY: cursorY)
        }
        dragAutoScrollController.updateFromDragLocation()
    }

    /// Commits the reorder on drag end, animating the list into the landing
    /// slot, then clears the drag state.
    func sidebarReorderGestureEnded(draggedId: UUID) {
        defer {
            dragState.cancelledReorderTabId = nil
            dragState.clearDrag()
            dragAutoScrollController.stop()
        }
        guard dragState.draggedTabId == draggedId,
              let targetIndex = dragState.gestureReorderTargetIndex() else {
            #if DEBUG
            cmuxDebugLog("sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=nil (noop)")
            #endif
            return
        }
        let usesTopLevelRows = dragState.dropIndicatorUsesTopLevelRows
        #if DEBUG
        cmuxDebugLog("sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=\(targetIndex) topLevel=\(usesTopLevelRows)")
        #endif
        withAnimation(Self.sidebarReorderAnimation) {
            _ = tabManager.reorderSidebarWorkspace(
                tabId: draggedId,
                toIndex: targetIndex,
                isDragOperation: true,
                usesTopLevelRows: usesTopLevelRows
            )
        }
    }

    /// Maps each reorder-scope id to the rendered rows that compose its hit-test
    /// band. Empty (identity) in normal mode; in top-level mode each group
    /// anchor's band spans its header plus its members so the group reads as one
    /// drop target.
    func sidebarReorderScopeBandComposition(
        usesTopLevelRows: Bool,
        renderContext: WorkspaceListRenderContext
    ) -> [UUID: [UUID]] {
        guard usesTopLevelRows else { return [:] }
        var composition: [UUID: [UUID]] = [:]
        for group in renderContext.workspaceGroupById.values {
            let memberIds = renderContext.tabs
                .filter { $0.groupId == group.id && $0.id != group.anchorWorkspaceId }
                .map(\.id)
            composition[group.anchorWorkspaceId] = [group.anchorWorkspaceId] + memberIds
        }
        return composition
    }
}

/// Attaches the reorder `DragGesture` to a row. The gesture runs in the shared
/// `"sidebarReorderList"` space so its location aligns with the measured row
/// frames. A non-zero `minimumDistance` lets a plain click still select the row.
struct SidebarReorderDragModifier: ViewModifier {
    let onChanged: (_ startLocation: CGPoint, _ location: CGPoint) -> Void
    let onEnded: (_ startLocation: CGPoint, _ location: CGPoint) -> Void

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(SidebarReorderListCoordinateSpace.name))
                .onChanged { value in onChanged(value.startLocation, value.location) }
                .onEnded { value in onEnded(value.startLocation, value.location) }
        )
    }
}

extension View {
    func sidebarReorderDrag(
        onChanged: @escaping (_ startLocation: CGPoint, _ location: CGPoint) -> Void,
        onEnded: @escaping (_ startLocation: CGPoint, _ location: CGPoint) -> Void
    ) -> some View {
        modifier(SidebarReorderDragModifier(onChanged: onChanged, onEnded: onEnded))
    }
}

/// Adds the reorder gesture and frame reporter to an interactive sidebar row.
/// `enabled` is constant for a given row role, so the `if` never re-keys view
/// identity at runtime; the follower copy passes `enabled: false` to stay
/// non-interactive and report no frame.
struct SidebarReorderRowModifier: ViewModifier {
    let enabled: Bool
    let workspaceId: UUID
    let onChanged: (_ startLocation: CGPoint, _ location: CGPoint) -> Void
    let onEnded: (_ startLocation: CGPoint, _ location: CGPoint) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .sidebarReorderRowFrame(workspaceId)
                .sidebarReorderDrag(onChanged: onChanged, onEnded: onEnded)
        } else {
            content
        }
    }
}
