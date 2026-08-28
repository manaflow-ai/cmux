import AppKit

/// Event-owning NSTableView for the default workspace sidebar.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
    /// AppKit can retain this table as a native drag source after SwiftUI
    /// dismantles its representable. Keep the controller alive until the
    /// terminal source callback arrives.
    var activeWorkspaceDragController: SidebarWorkspaceTableController?
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var lastPointerWindowLocation: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        pointerTrackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerWindowLocation(nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else {
            super.otherMouseDown(with: event)
            return
        }
        workspaceController?.middleClick(row: row)
    }

    override func mouseDown(with event: NSEvent) {
        workspaceController?.prepareForMouseDown()
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        // No selection paint on press: the highlight applies on down-then-up
        // (owner ruling). The action fires on mouse-up and paints the
        // optimistic treatment there, so a press that becomes a drag or a
        // cancelled click never shows a speculative highlight at all.
        super.mouseDown(with: event)
        if event.clickCount == 2, clickedRow < 0 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return workspaceController?.emptyAreaMenu() }
        // AppKit can ask the table for a Control-click but the cell for a
        // physical right-click. Resolve the row here so both gestures reach
        // the same live cell-owned menu provider.
        return workspaceController?.menu(forRow: row, event: event)
            ?? super.menu(for: event)
    }

    private func updatePointer(with event: NSEvent) {
        setPointerWindowLocation(event.locationInWindow)
    }

    func setPointerWindowLocation(_ point: NSPoint?) {
        lastPointerWindowLocation = point
        if point == nil {
            workspaceController?.pointerDidLeaveTable()
        } else {
            workspaceController?.recomputeHoveredRow()
        }
    }
}
