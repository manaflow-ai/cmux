import AppKit

/// Scroll viewport that preserves empty-area double-click and context-menu behavior.
@MainActor
final class SidebarWorkspaceTableClipView: NSClipView {
    weak var workspaceController: SidebarWorkspaceTableController?

    override func mouseDown(with event: NSEvent) {
        // Presses only reach the clip view when they miss the table's frame
        // entirely, so anything landing here is empty space by construction.
        if event.clickCount == 1,
           SidebarEmptyAreaWindowDrag.perform(with: event, in: self) {
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        workspaceController?.emptyAreaMenu()
    }
}
