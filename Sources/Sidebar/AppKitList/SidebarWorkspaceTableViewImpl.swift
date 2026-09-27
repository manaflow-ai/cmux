import AppKit

/// Event-owning NSTableView for the default workspace sidebar.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
    /// AppKit can retain this table as a native drag source after SwiftUI
    /// dismantles its representable. Keep the controller alive until the
    /// terminal source callback arrives.
    var activeWorkspaceDragController: SidebarWorkspaceTableController?
    private let emptyAreaWindowDragController = SidebarEmptyAreaWindowDragController()
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var lastPointerWindowLocation: NSPoint?

    /// Pointer location for hover recomputes that no event drove (content
    /// applies, menu close, viewport changes). Tracking events stop while a
    /// context menu or drag session runs, so the cached point can be where
    /// the pointer was when the menu opened. "Close Workspace" from a row
    /// menu then revealed the X on whichever row slid into that old spot.
    /// Read the live pointer instead, and only while the tracking area
    /// still has the pointer inside the table.
    var livePointerWindowLocation: NSPoint? {
        guard lastPointerWindowLocation != nil, let window else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

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

    /// Preserves row clicks while promoting threshold-crossing empty-area presses to window drags.
    override func mouseDown(with event: NSEvent) {
        workspaceController?.prepareForMouseDown()
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        // Below the last row the press is window-drag territory. Single clicks
        // only: a double-click still belongs to doubleClickEmptyArea().
        if clickedRow < 0, event.clickCount == 1,
           emptyAreaWindowDragController.perform(with: event, in: self) != .passThrough {
            return
        }
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
        guard row < 0 else { return super.menu(for: event) }
        return workspaceController?.emptyAreaMenu()
    }

    private func updatePointer(with event: NSEvent) {
        setPointerWindowLocation(event.locationInWindow)
    }

    func setPointerWindowLocation(_ point: NSPoint?) {
        lastPointerWindowLocation = point
        if point == nil {
            workspaceController?.pointerDidLeaveTable()
        } else {
            workspaceController?.recomputeHoveredRow(windowPoint: point)
        }
    }
}
