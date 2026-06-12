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
/// zero lag while the list rows animate the gap open underneath it.
struct SidebarReorderFollowerView: View {
    let dragState: SidebarDragState
    /// The committed render list, used to find the picked-up row's content.
    let sourceItems: [SidebarWorkspaceRenderItem]
    let rowContent: (SidebarWorkspaceRenderItem) -> AnyView

    var body: some View {
        if let draggedId = dragState.draggedTabId,
           let cursorY = dragState.followerCursorY,
           let frame = dragState.draggedRowFrame,
           frame.width > 0,
           frame.height > 0,
           let item = sourceItems.first(where: { $0.representedWorkspaceId == draggedId }) {
            let topY = cursorY - dragState.grabOffsetY
            rowContent(item)
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
