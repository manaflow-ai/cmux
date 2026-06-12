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
///
/// The membership indent is NOT animated here: `followerRenderedIndent` is
/// animated at its single mutation site (`SidebarDragState.setPreviewMembership`
/// wraps the write in `withAnimation`), so every way a flip can happen —
/// vertical slot crossing, in-place X nudge — animates identically. This view
/// just renders the value. Cursor tracking stays animation-free because the
/// `followerCursorY` writes are never wrapped in `withAnimation` and no
/// animation modifier covers `.position`.
struct SidebarReorderFollowerView: View {
    let dragState: SidebarDragState
    /// The committed render list, used to find the picked-up row's content
    /// (and, for a header drag, the member rows that follow it).
    let sourceItems: [SidebarWorkspaceRenderItem]
    /// Spacing between the header and member rows in a group-block follower,
    /// matching the list's row spacing.
    let rowSpacing: CGFloat
    let rowContent: (SidebarWorkspaceRenderItem) -> AnyView

    var body: some View {
        if let draggedId = dragState.draggedTabId,
           let cursorY = dragState.followerCursorY,
           let frame = dragState.draggedRowFrame,
           frame.width > 0,
           frame.height > 0,
           let itemIndex = sourceItems.firstIndex(where: { $0.representedWorkspaceId == draggedId }) {
            let topY = cursorY - dragState.grabOffsetY
            let indent = dragState.followerRenderedIndent
            let blockItems = followerBlockItems(startingAt: itemIndex)
            // Width and X are BOTH functions of the rendered indent: tucking
            // into a group slides the row right by the indent AND narrows it
            // by the same amount (the trailing edge stays fixed). The outer
            // fixed-size container keeps the cursor anchor math stable; a
            // group block overflows below it without clipping.
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(blockItems, id: \.representedWorkspaceId) { item in
                    rowContent(item)
                }
            }
            .frame(width: max(frame.width - indent, 0), height: frame.height, alignment: .topLeading)
            .padding(.leading, indent)
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
