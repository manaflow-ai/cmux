import AppKit
import CmuxFoundation
import QuartzCore

/// Event-owning NSTableView for the default workspace sidebar.
@MainActor
final class SidebarWorkspaceTableViewImpl: NSTableView {
    weak var workspaceController: SidebarWorkspaceTableController?
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var lastPointerWindowLocation: NSPoint?
    private var manualSystemDragHandoff = false

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
        let hitView = hitTest(point)
        if let workspaceController,
           let window,
           workspaceController.shouldOwnDirectReorderMouseDown(
               row: clickedRow,
               event: event,
               hitView: hitView
           ) {
            trackDirectReorder(
                from: event,
                row: clickedRow,
                hitView: hitView,
                window: window,
                workspaceController: workspaceController
            )
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

    /// Synchronous AppKit pointer tracking, matching `NSSplitView` and the
    /// sidebar divider. The latest queued drag event wins each frame, so a
    /// high-polling mouse cannot build a backlog between pointer and row gap.
    private func trackDirectReorder(
        from mouseDown: NSEvent,
        row: Int,
        hitView: NSView?,
        window: NSWindow,
        workspaceController: SidebarWorkspaceTableController
    ) {
        let origin = window.convertPoint(toScreen: mouseDown.locationInWindow)
        var gesture = SidebarWorkspaceDirectReorderGesture(
            origin: origin,
            windowBounds: window.frame,
            dragThreshold: 4,
            systemHandoffMargin: 28
        )
        var didBeginReorder = false
        let trackedEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .keyDown]

        while true {
            guard var next = window.nextEvent(
                matching: trackedEvents,
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            while next.type == .leftMouseDragged,
                  let queued = window.nextEvent(
                      matching: trackedEvents,
                      until: Date(),
                      inMode: .eventTracking,
                      dequeue: true
                  ) {
                next = queued
            }

            if next.type == .keyDown {
                if next.keyCode == 53 {
                    if gesture.cancel() == .cancelReorder, didBeginReorder {
                        workspaceController.directReorderCancelled()
                    }
                    return
                }
                NSApp.sendEvent(next)
                continue
            }

            let screenPoint = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseUp {
                switch gesture.release(at: screenPoint) {
                case .click:
                    workspaceController.performPrimaryClick(
                        row: row,
                        modifiers: mouseDown.modifierFlags,
                        hitView: hitView
                    )
                case .commitReorder(let point):
                    workspaceController.directReorderEnded(at: point)
                default:
                    break
                }
                return
            }

            switch gesture.drag(to: screenPoint) {
            case .beginReorder:
                guard workspaceController.directReorderWillBegin(row: row, at: origin) else {
                    return
                }
                didBeginReorder = true
                workspaceController.directReorderMoved(to: screenPoint)
                presentDirectReorderFrame(in: window)
            case .updateReorder(let point):
                workspaceController.directReorderMoved(to: point)
                presentDirectReorderFrame(in: window)
            case .handoffToSystemDrag:
                if !didBeginReorder {
                    guard workspaceController.directReorderWillBegin(row: row, at: origin) else {
                        return
                    }
                    didBeginReorder = true
                }
                workspaceController.directReorderHandedOffToSystemDrag()
                beginSystemDragHandoff(row: row, event: next)
                return
            default:
                break
            }
        }
    }

    private func presentDirectReorderFrame(in window: NSWindow) {
        RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// One-way escalation for true cross-window movement. The local renderer
    /// has already torn down, so AppKit owns every subsequent drag event.
    private func beginSystemDragHandoff(row: Int, event: NSEvent) {
        guard let workspaceController,
              let item = workspaceController.workspaceDragPasteboardItem(row: row) else {
            workspaceController?.systemDragHandoffDidEnd()
            return
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let rowFrame = rect(ofRow: row)
        draggingItem.setDraggingFrame(rowFrame, contents: dragSnapshot(row: row))
        manualSystemDragHandoff = true
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func dragSnapshot(row: Int) -> NSImage? {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false),
              cell.bounds.width > 0,
              cell.bounds.height > 0,
              let representation = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else {
            return nil
        }
        cell.cacheDisplay(in: cell.bounds, to: representation)
        let image = NSImage(size: cell.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    override func cancelOperation(_ sender: Any?) {
        _ = workspaceController?.localReorderCancelOperation()
        super.cancelOperation(sender)
    }

    /// NSTableView is the dragging source, so this callback continues while
    /// the pointer is outside the sidebar and its destination overlay.
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        super.draggingSession(session, movedTo: screenPoint)
        workspaceController?.localReorderDraggingSession(session, movedTo: screenPoint)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        guard manualSystemDragHandoff else { return }
        manualSystemDragHandoff = false
        workspaceController?.systemDragHandoffDidEnd()
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
