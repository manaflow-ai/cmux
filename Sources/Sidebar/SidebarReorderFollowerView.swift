import SwiftUI

/// The floating copy of the picked-up workspace row that tracks the cursor
/// during a gesture-driven reorder.
///
/// This is the ONLY view that reads `SidebarDragState.followerCursorY`, the
/// per-frame cursor position. Because it is a sibling overlay over the list (not
/// a row inside the `LazyVStack`/`ForEach`), its per-frame updates repaint just
/// this one view and never invalidate the list body — the property that keeps
/// the drag off the https://github.com/manaflow-ai/cmux/issues/2586 thrash path.
/// Implicit animations are disabled so the follower snaps to the cursor with
/// zero lag while the list rows animate the gap open underneath it — except the
/// group-membership indent, which animates on its own axis (see below).
struct SidebarReorderFollowerView: View {
    let dragState: SidebarDragState
    /// The committed render list, used to find the picked-up row's content.
    let sourceItems: [SidebarWorkspaceRenderItem]
    /// Extra leading indent previewed for the dragged row at its current
    /// landing slot (member indent when the slot is inside a group the row is
    /// not yet a member of, 0 otherwise). Derived by the parent from the
    /// preview items, so it only changes when the landing slot does.
    let previewExtraIndent: CGFloat
    let rowContent: (SidebarWorkspaceRenderItem) -> AnyView

    var body: some View {
        if let draggedId = dragState.draggedTabId,
           let cursorY = dragState.followerCursorY,
           let frame = dragState.draggedRowFrame,
           frame.width > 0,
           frame.height > 0,
           let item = sourceItems.first(where: { $0.representedWorkspaceId == draggedId }) {
            let topY = cursorY - dragState.grabOffsetY
            // Parking over a header's drop-into zone also previews membership.
            let extraIndent = dragState.dropIntoGroupAnchorId != nil
                ? SidebarWorkspaceGroupingMetrics.memberIndent
                : previewExtraIndent
            // The indent is applied INSIDE the fixed-size, position-tracked
            // container, on its own animation keyed to the indent value: the
            // row slides right and narrows when the landing slot crosses into
            // a group (and back out), while Y stays glued to the cursor with
            // animations disabled.
            rowContent(item)
                .padding(.leading, extraIndent)
                .animation(.snappy(duration: 0.15, extraBounce: 0), value: extraIndent)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .position(x: frame.midX, y: topY + frame.height / 2)
                .shadow(color: Color.black.opacity(0.18), radius: 11, x: 0, y: 5)
                .opacity(0.97)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(1000)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
        }
    }
}
