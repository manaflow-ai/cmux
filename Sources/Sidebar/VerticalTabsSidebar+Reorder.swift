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
    /// The cursor is derived from the gesture's TRANSLATION, not its location:
    /// `DragGesture` converts locations through the host row's current
    /// geometry, and the preview moves that row to the landing slot mid-drag,
    /// so location jumps by the row's displacement on every preview reflow —
    /// a feedback loop (cursor jump → indicator jump → preview move → cursor
    /// jump) seen in the dogfood log as ±row-band cursorY oscillation.
    /// Translation is a pure pointer delta and is immune to host movement; it
    /// is anchored to the begin-time location (geometry-consistent, the
    /// preview has not moved yet) plus the accumulated autoscroll delta.
    ///
    /// - Parameters:
    ///   - draggedId: the workspace (or group anchor) being dragged.
    ///   - startLocationY: the gesture's start Y in the named list space. No
    ///     longer used to anchor the drag (it is viewport-wrong under scroll);
    ///     the anchor is the row's frozen-frame center. Kept for the API shape.
    ///   - translation: the gesture's pointer travel. Height drives the slot,
    ///     width drives boundary-slot group membership (the outliner X axis).
    func sidebarReorderGestureChanged(
        draggedId: UUID,
        startLocationY: CGFloat,
        translation: CGSize,
        renderContext: WorkspaceListRenderContext
    ) {
        // Escape cancelled this drag mid-gesture. The DragGesture itself stays
        // alive until the mouse releases and keeps streaming onChanged; without
        // this latch the next event would re-begin the cancelled drag.
        guard dragState.cancelledReorderTabId != draggedId else { return }
        // The cursor's CONTENT-space Y = the grab point (frozen frame top +
        // within-row offset) + the pure translation + any autoscroll. The
        // grab point is captured once at begin into reorderTranslationBaseY,
        // so this formula is identical for begin and update and never touches
        // the unreliable absolute gesture location.
        let updateCursorY = dragState.reorderTranslationBaseY
            + translation.height
            + dragState.autoScrollAccumulatedDelta
        if dragState.draggedTabId != draggedId {
            let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedId,
                targetWorkspaceId: nil
            )
            let reorderIds = tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedId,
                usesTopLevelRows: usesTopLevelRows
            )
            // The dragged row itself is excluded from the pinned-tier clamp:
            // its slots must not be pre-clamped to the tier before membership
            // resolves (dragging a pinned row into a group, or out of the
            // tier, unpins it at commit — the preview must be able to show
            // those slots). Anchor/top-level drags keep the full set, since
            // group pinning is positional, not membership-driven.
            var pinnedIds = tabManager.sidebarReorderPinnedWorkspaceIds(
                forDraggedWorkspaceId: draggedId,
                usesTopLevelRows: usesTopLevelRows
            )
            if !usesTopLevelRows {
                pinnedIds.remove(draggedId)
            }
            let composition = sidebarReorderScopeBandComposition(
                usesTopLevelRows: usesTopLevelRows,
                renderContext: renderContext
            )
            // Membership-resolution inputs: each band's group identity and
            // which bands are headers.
            let draggedWorkspace = renderContext.workspaceById[draggedId]
            let draggedGroupId = draggedWorkspace?.groupId
            let draggedIsAnchor = renderContext.workspaceGroups
                .contains { $0.anchorWorkspaceId == draggedId }
            let bandGroupIdById: [UUID: UUID?] = Dictionary(
                uniqueKeysWithValues: renderContext.tabs.map { ($0.id, $0.groupId) }
            )
            let headerBandIds = Set(renderContext.workspaceGroups.map(\.anchorWorkspaceId))
            let collapsedAnchorIds = Set(
                renderContext.workspaceGroups.filter(\.isCollapsed).map(\.anchorWorkspaceId)
            )
            let frame = dragState.rowFramesInList[draggedId]
            // Anchor to the row's frozen-frame CENTER plus the stable
            // translation. With grabOffsetY = height/2 the follower top works
            // out to rowMinY + translation, so the row sits at its committed
            // spot at grab (no jump) and moves by exactly the drag delta (the
            // grabbed point stays under the pointer), and the probe is the
            // item center + translation. Nothing here depends on the absolute
            // gesture location (viewport-wrong under scroll) or a per-grab
            // offset, so it is fully scroll-independent.
            let rowCenterY = frame?.midY ?? 0
            let grabOffsetY = (frame?.height ?? 0) / 2
            let beginCursorY = rowCenterY + translation.height
            #if DEBUG
            cmuxDebugLog(
                "sidebar.reorder.begin id=\(draggedId.uuidString.prefix(5)) " +
                "rowCenterY=\(Int(rowCenterY)) grabOff=\(Int(grabOffsetY)) " +
                "cursorY=\(Int(beginCursorY)) followerTop=\(Int(beginCursorY - grabOffsetY)) " +
                "transY=\(Int(translation.height)) " +
                "topLevel=\(usesTopLevelRows) scope=\(reorderIds.count) " +
                "frames=\(dragState.rowFramesInList.count) hasOwnFrame=\(frame != nil) " +
                "ownFrame=\(frame.map { "\(Int($0.minY))..\(Int($0.maxY))" } ?? "nil")"
            )
            #endif
            dragState.beginReorder(
                tabId: draggedId,
                usesTopLevelRows: usesTopLevelRows,
                reorderIds: reorderIds,
                pinnedIds: pinnedIds,
                scopeBandComposition: composition,
                bandGroupIdById: bandGroupIdById,
                headerBandIds: headerBandIds,
                collapsedAnchorBandIds: collapsedAnchorIds,
                draggedCommittedGroupId: draggedGroupId,
                draggedIsAnchor: draggedIsAnchor,
                draggedRowFrame: frame,
                grabOffsetY: grabOffsetY,
                translationBaseY: rowCenterY,
                cursorY: beginCursorY
            )
        } else {
            dragState.updateReorder(cursorY: updateCursorY, translationWidth: translation.width)
        }
        dragAutoScrollController.updateFromDragLocation()
    }

    /// Commits the reorder on drag end, animating the list into the landing
    /// slot, then clears the drag state. A group that THIS drag spring-expanded
    /// is collapsed again unless the dragged row landed inside it.
    func sidebarReorderGestureEnded(draggedId: UUID) {
        let autoExpandedGroupId = dragState.springAutoExpandedGroupId
        let landedGroupId = commitGestureReorder(draggedId: draggedId)
        if let autoExpandedGroupId, landedGroupId != autoExpandedGroupId,
           let group = tabManager.workspaceGroups.first(where: { $0.id == autoExpandedGroupId }),
           !group.isCollapsed {
            withAnimation(SidebarGroupAnimation.collapse) {
                tabManager.setWorkspaceGroupCollapsed(groupId: autoExpandedGroupId, isCollapsed: true)
            }
        }
        dragState.cancelledReorderTabId = nil
        dragState.clearDrag()
        dragAutoScrollController.stop()
    }

    /// Applies the drop and returns the group the dragged row landed inside
    /// (nil for a top-level/anchor move, a no-op, or a drop outside any group).
    @discardableResult
    private func commitGestureReorder(draggedId: UUID) -> UUID? {
        guard dragState.draggedTabId == draggedId else {
            #if DEBUG
            cmuxDebugLog("sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=nil (noop)")
            #endif
            return nil
        }
        guard let targetIndex = dragState.gestureReorderTargetIndex() else {
            // No positional move — but the X axis may have flipped membership
            // in place (tuck into the group directly above / pull out at the
            // group's edge without moving). Commit the membership-only drop
            // at the row's current index.
            let membership = dragState.previewMembershipGroupId
            if !dragState.dropIndicatorUsesTopLevelRows,
               let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedId }),
               membership != tabManager.tabs[currentIndex].groupId {
                #if DEBUG
                cmuxDebugLog(
                    "sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=inPlace " +
                    "membership=\(membership?.uuidString.prefix(5) ?? "nil")"
                )
                #endif
                withAnimation(Self.sidebarReorderAnimation) {
                    _ = tabManager.applyGestureDragReorder(
                        tabId: draggedId,
                        toIndex: currentIndex,
                        desiredGroupId: membership
                    )
                }
                return membership
            }
            #if DEBUG
            cmuxDebugLog("sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=nil (noop)")
            #endif
            return tabManager.tabs.first(where: { $0.id == draggedId })?.groupId
        }
        let usesTopLevelRows = dragState.dropIndicatorUsesTopLevelRows
        if usesTopLevelRows {
            #if DEBUG
            cmuxDebugLog("sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=\(targetIndex) topLevel=true")
            #endif
            withAnimation(Self.sidebarReorderAnimation) {
                _ = tabManager.reorderSidebarWorkspace(
                    tabId: draggedId,
                    toIndex: targetIndex,
                    isDragOperation: true,
                    usesTopLevelRows: true
                )
            }
            return nil
        }
        // Membership was resolved live (interior slots force it, boundary
        // slots followed the pointer's X) and is committed explicitly so the
        // drop lands exactly what the preview showed.
        let membership = dragState.previewMembershipGroupId
        #if DEBUG
        cmuxDebugLog(
            "sidebar.reorder.end id=\(draggedId.uuidString.prefix(5)) target=\(targetIndex) " +
            "membership=\(membership?.uuidString.prefix(5) ?? "nil")"
        )
        #endif
        withAnimation(Self.sidebarReorderAnimation) {
            _ = tabManager.applyGestureDragReorder(
                tabId: draggedId,
                toIndex: targetIndex,
                desiredGroupId: membership
            )
        }
        return membership
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
    let onChanged: (_ startLocation: CGPoint, _ translation: CGSize) -> Void
    let onEnded: (_ startLocation: CGPoint, _ translation: CGSize) -> Void

    func body(content: Content) -> some View {
        content.gesture(
            // The named LIST space (not `.local`) so `translation` is measured
            // against a FIXED reference and is not corrupted by the dragged
            // row's own movement during the drag (which `.local` does — the
            // gesture host moves to the preview slot, making `.local`
            // translation alternate). The absolute startLocation this space
            // reports is unreliable under scroll, so the drag does NOT use it:
            // it anchors to the row's frozen-frame center plus this stable
            // translation instead.
            DragGesture(minimumDistance: 6, coordinateSpace: .named(SidebarReorderListCoordinateSpace.name))
                .onChanged { value in onChanged(value.startLocation, value.translation) }
                .onEnded { value in onEnded(value.startLocation, value.translation) }
        )
    }
}

extension View {
    func sidebarReorderDrag(
        onChanged: @escaping (_ startLocation: CGPoint, _ translation: CGSize) -> Void,
        onEnded: @escaping (_ startLocation: CGPoint, _ translation: CGSize) -> Void
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
    let onChanged: (_ startLocation: CGPoint, _ translation: CGSize) -> Void
    let onEnded: (_ startLocation: CGPoint, _ translation: CGSize) -> Void

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
