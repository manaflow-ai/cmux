import AppKit

/// Scroll viewport that preserves empty-area double-click and context-menu behavior.
@MainActor
final class SidebarWorkspaceTableClipView: NSClipView {
    weak var workspaceController: SidebarWorkspaceTableController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        workspaceController?.emptyAreaMenu()
    }
}
