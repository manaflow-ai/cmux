import SwiftUI

/// The floating copy of the picked-up workspace row that tracks the cursor
/// during a gesture-driven reorder. For a group-header drag the follower
/// carries the WHOLE visible block (header + member rows) so the group reads
/// as one object traveling with the cursor.
///
/// This is the ONLY view that reads `SidebarDragState.followerCursorY`, the
/// per-frame cursor position. Because it is a sibling overlay over the list (not
/// a row inside the `LazyVStack`/`ForEach`), its per-frame updates repaint just
/// this one view and never invalidate the list body — the property that keeps
/// the drag off the https://github.com/manaflow-ai/cmux/issues/2586 thrash path.
/// The cursor tracking stays animation-free by construction: `.position` sits
/// OUTSIDE the indent's `.animation(_:value:)` scope, no other animation
/// modifier covers it, and `followerCursorY` writes are never wrapped in
/// `withAnimation` — so the follower snaps to the cursor with zero lag while
/// the indent/width animate on their own axis. (A blanket
/// `.transaction { disablesAnimations = true }` used to enforce this, but it
/// also suppressed the indent animation — disablesAnimations kills
/// `.animation(_:value:)` downstream — so it must not come back.)
struct SidebarReorderFollowerView: View {
    let dragState: SidebarDragState
    /// The committed render list, used to find the picked-up row's content
    /// (and, for a header drag, the member rows that follow it).
    let sourceItems: [SidebarWorkspaceRenderItem]
    /// Spacing between the header and member rows in a group-block follower,
    /// matching the list's row spacing.
    let rowSpacing: CGFloat
    /// Extra leading indent previewed for the dragged row at its current
    /// landing slot, RELATIVE to its committed indent (positive tucking into
    /// a group, negative pulling out, 0 unchanged). Derived by the parent
    /// from the resolved membership, so it only changes when the resolved
    /// membership does.
    let previewExtraIndent: CGFloat
    let rowContent: (SidebarWorkspaceRenderItem) -> AnyView

    var body: some View {
        if let draggedId = dragState.draggedTabId,
           let cursorY = dragState.followerCursorY,
           let frame = dragState.draggedRowFrame,
           frame.width > 0,
           frame.height > 0,
           let itemIndex = sourceItems.firstIndex(where: { $0.representedWorkspaceId == draggedId }) {
            let topY = cursorY - dragState.grabOffsetY
            let blockItems = followerBlockItems(startingAt: itemIndex)
            // The indent is applied INSIDE the position-tracked container, on
            // its own animation keyed to the indent value: the row slides
            // right and narrows when the landing slot crosses into a group
            // (and back out), while Y stays glued to the cursor with
            // animations disabled. The container is sized to the picked-up
            // row's frame and top-aligned, so a group block overflows below
            // it without disturbing the cursor anchor math.
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(blockItems, id: \.representedWorkspaceId) { item in
                    rowContent(item)
                }
            }
            // Width and X are BOTH explicit functions of the previewed
            // indent: tucking into a group slides the row right by the
            // indent AND narrows it by the same amount (the trailing edge
            // stays fixed), animated together on the indent's own axis while
            // Y tracking below stays animation-free.
            .frame(width: max(frame.width - previewExtraIndent, 0), height: frame.height, alignment: .topLeading)
            .padding(.leading, previewExtraIndent)
            .animation(.snappy(duration: 0.15, extraBounce: 0), value: previewExtraIndent)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .position(x: frame.midX, y: topY + frame.height / 2)
            .shadow(color: Color.black.opacity(0.18), radius: 11, x: 0, y: 5)
            .opacity(0.97)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(1000)
        }
    }

    /// The dragged item plus, for a group header, the visible member rows
    /// that follow it in the committed list (capped so enormous groups don't
    /// turn the per-frame follower into a wall of rows).
    private func followerBlockItems(startingAt itemIndex: Int) -> [SidebarWorkspaceRenderItem] {
        let item = sourceItems[itemIndex]
        guard case .groupHeader(let group, _) = item else { return [item] }
        var block: [SidebarWorkspaceRenderItem] = [item]
        var index = itemIndex + 1
        while index < sourceItems.count, block.count < 7 {
            guard case .workspace(let workspace, _) = sourceItems[index],
                  workspace.groupId == group.id else { break }
            block.append(sourceItems[index])
            index += 1
        }
        return block
    }
}
