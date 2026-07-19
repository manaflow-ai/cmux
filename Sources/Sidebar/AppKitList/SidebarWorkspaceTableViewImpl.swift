import AppKit

/// Event-owning NSTableView for the default workspace sidebar.
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
        // Arc-feel: paint the selection highlight on press, before the
        // click tracking loop and the model round trip confirm it.
        if clickedRow >= 0 {
            let hitView = superview.flatMap { hitTest($0.convert(event.locationInWindow, from: nil)) }
            workspaceController?.previewSelection(
                row: clickedRow,
                modifiers: event.modifierFlags,
                hitView: hitView
            )
        }
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
            workspaceController?.recomputeHoveredRow()
        }
    }
}
