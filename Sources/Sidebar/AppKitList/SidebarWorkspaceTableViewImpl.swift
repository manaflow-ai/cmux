import AppKit

/// Event-owning NSTableView for the default workspace sidebar.
///
/// This view is the single pointer owner for the list: hover, click
/// selection, inline-rename double-clicks, middle-click close, empty-area
/// gestures, and context menus all resolve here and route to the controller.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
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
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if event.clickCount == 2, clickedRow >= 0 {
            workspaceController?.doubleClick(row: clickedRow)
            return
        }
        // The table's own tracking loop arbitrates click vs. drag: it returns
        // after mouse-up, having begun a drag session (via
        // `pasteboardWriterForRow`) if the pointer moved past the slop.
        workspaceController?.willTrackMouseDown()
        super.mouseDown(with: event)
        if clickedRow >= 0 {
            if !(workspaceController?.didBeginDragDuringMouseTracking ?? false) {
                workspaceController?.click(row: clickedRow, modifierFlags: event.modifierFlags)
            }
        } else if event.clickCount == 2 {
            workspaceController?.doubleClickEmptyArea()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return workspaceController?.emptyAreaMenu() }
        return workspaceController?.menu(forRow: row)
    }

    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        // Buttons, link buttons, and the inline-rename field inside cells must
        // receive their events directly; everything else routes to the table.
        if responder is NSControl { return true }
        return super.validateProposedFirstResponder(responder, for: event)
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
