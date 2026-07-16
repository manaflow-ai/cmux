import AppKit

/// Native event surface for the AppKit workspace sidebar.
///
/// Row identity and models stay in the controller. This view reports only row
/// indexes, which keeps pointer movement, context menus, and middle clicks from
/// resolving snapshots or walking the workspace collection.
@MainActor
final class SidebarAppKitTableView: NSTableView {
    final class RowView: NSTableRowView {
        var isPointerHovering = false {
            didSet {
                guard isPointerHovering != oldValue else { return }
                needsDisplay = true
            }
        }

        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            guard isPointerHovering, !isSelected else { return }
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 6, dy: 1),
                xRadius: 4,
                yRadius: 4
            ).fill()
        }

        override func drawSelection(in dirtyRect: NSRect) {
            guard selectionHighlightStyle != .none else { return }
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.24).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 6, dy: 1),
                xRadius: 4,
                yRadius: 4
            ).fill()
        }
    }

    var onHoveredRowChanged: ((Int?, Int?) -> Void)?
    var onPrimaryClick: ((Int, NSEvent) -> Void)?
    var onMiddleClick: ((Int, NSEvent) -> Bool)?
    var contextMenuProvider: ((Int, NSEvent) -> NSMenu?)?
    var onEmptyAreaDoubleClick: (() -> Void)?
    var emptyAreaContextMenuProvider: ((NSEvent) -> NSMenu?)?
    var onVisibleRowsMayHaveChanged: (() -> Void)?

    private(set) var hoveredRow: Int?
    private(set) var lastSelectionModifierFlags: NSEvent.ModifierFlags = []
    private(set) var isHandlingPointerSelection = false
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        pointerTrackingArea = next
        reconcileHoveredRow()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredRow(for: event)
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredRow(for: event)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        lastSelectionModifierFlags = event.modifierFlags
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0, event.clickCount >= 2, let onEmptyAreaDoubleClick {
            onEmptyAreaDoubleClick()
            return
        }
        if row >= 0, event.clickCount == 1 {
            onPrimaryClick?(row, event)
        }
        isHandlingPointerSelection = true
        super.mouseDown(with: event)
        isHandlingPointerSelection = false
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, onMiddleClick?(row, event) == true else {
            super.otherMouseDown(with: event)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        lastSelectionModifierFlags = event.modifierFlags
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else {
            return emptyAreaContextMenuProvider?(event) ?? super.menu(for: event)
        }
        return contextMenuProvider?(row, event) ?? super.menu(for: event)
    }

    override func layout() {
        super.layout()
        reconcileHoveredRow()
        onVisibleRowsMayHaveChanged?()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        reconcileHoveredRow()
        onVisibleRowsMayHaveChanged?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reconcileHoveredRow()
        onVisibleRowsMayHaveChanged?()
    }

    func reconcileHoveredRow() {
        guard let window else {
            setHoveredRow(nil)
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location) else {
            setHoveredRow(nil)
            return
        }
        let row = row(at: location)
        setHoveredRow(row >= 0 ? row : nil)
    }

    private func updateHoveredRow(for event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        setHoveredRow(row >= 0 ? row : nil)
    }

    private func setHoveredRow(_ next: Int?) {
        guard next != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = next
        onHoveredRowChanged?(previous, next)
    }
}

/// Handles clicks in the viewport below a short table. NSTableView receives
/// events over realized row geometry; the clip view owns the remaining empty
/// area so new-workspace and context-menu behavior does not depend on row count.
@MainActor
final class SidebarAppKitClipView: NSClipView {
    var onEmptyAreaDoubleClick: (() -> Void)?
    var emptyAreaContextMenuProvider: ((NSEvent) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, pointsToEmptyTableArea(event) {
            onEmptyAreaDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard pointsToEmptyTableArea(event) else { return super.menu(for: event) }
        return emptyAreaContextMenuProvider?(event) ?? super.menu(for: event)
    }

    private func pointsToEmptyTableArea(_ event: NSEvent) -> Bool {
        guard let tableView = documentView as? NSTableView else { return false }
        let point = tableView.convert(event.locationInWindow, from: nil)
        return tableView.row(at: point) < 0
    }
}
