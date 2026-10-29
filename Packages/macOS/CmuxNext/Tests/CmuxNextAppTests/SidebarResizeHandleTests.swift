import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// The sidebar's resize edge at most twice per frame (feature `pointerFrameDrags`):
/// with the window's FrameInputCoalescer the first drag event of a frame interval
/// resizes in its own turn and the rest resize once more at the frame, to the latest point; the
/// release lands the pending resize first.
@MainActor @Suite(.serialized) struct SidebarResizeHandleTests {
    final class Harness {
        let model = SidebarModel()
        let container: SidebarContainerView
        let window: NSWindow
        let frames = PointerFrameTestRig()
        var changes: [CGFloat] = []
        var phases: [String] = []

        init() {
            _ = NSApplication.shared
            model.width = Metrics.sidebarMinWidth + 20
            container = SidebarContainerView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
            host.addSubview(container)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            container.resizeFrameInput = frames.coalescers
            let forward = container.handle.onDrag
            container.handle.onDrag = { [unowned self] phase in
                switch phase {
                case .began: phases.append("began")
                case let .changed(dx):
                    phases.append("changed")
                    changes.append(dx)
                case .ended: phases.append("ended")
                }
                forward?(phase)
            }
        }

        var handle: SidebarResizeHandle { container.handle }

        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// The first drag event after an idle frame resizes in its own turn.
    @Test func theFirstDragResizesInTheSameTurn() {
        let harness = Harness()
        defer { harness.close() }
        let startWidth = harness.model.width
        let startX: CGFloat = 200
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + 6))
        #expect(harness.changes == [6])
        #expect(harness.model.width == startWidth + 6)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// Eight drag events in one frame resize the sidebar twice: the first at once, the rest at the
    /// frame, to the last event's width.
    @Test func eightDragsInOneFrameResizeAtMostTwice() {
        let harness = Harness()
        defer { harness.close() }
        let startWidth = harness.model.width
        let startX: CGFloat = 200
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        for step in 1...8 {
            harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + CGFloat(step) * 2))
        }
        #expect(harness.changes == [2], "only the leading drag resized before the frame")
        harness.frames.frame()
        #expect(harness.changes == [2, 16], "the frame resized once more, to the latest point")
        #expect(harness.model.width == startWidth + 16)
    }

    /// The release lands the pending resize before the drag ends.
    @Test func theReleaseFlushesThePendingResizeFirst() {
        let harness = Harness()
        defer { harness.close() }
        let startWidth = harness.model.width
        let startX: CGFloat = 200
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + 5))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + 9))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + 12))
        harness.handle.mouseUp(with: harness.event(.leftMouseUp, x: startX + 12))
        #expect(harness.phases == ["began", "changed", "changed", "ended"])
        #expect(harness.changes == [5, 12])
        #expect(harness.model.width == startWidth + 12)
        #expect(!harness.frames.coalescer.hasPending)
        harness.frames.frame()
        #expect(harness.phases.last == "ended", "nothing lands after the release")
    }

    /// A pending resize that hides the sidebar ends the drag: the release sends no second end.
    @Test func aFlushedResizeThatHidesTheSidebarEndsTheDrag() {
        let harness = Harness()
        defer { harness.close() }
        let startX: CGFloat = 400
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 4))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 380))
        harness.handle.mouseUp(with: harness.event(.leftMouseUp, x: startX - 380))
        #expect(harness.model.presentation == .hidden)
        #expect(harness.phases == ["began", "changed", "changed"])
        #expect(!harness.handle.isDragging)
    }

    /// With no frame-aligned input (the feature off), every drag event resizes at once.
    @Test func withoutFrameInputEveryEventResizes() {
        let harness = Harness()
        defer { harness.close() }
        harness.container.resizeFrameInput = nil
        let startX: CGFloat = 200
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        for step in 1...8 {
            harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + CGFloat(step) * 2))
        }
        #expect(harness.changes.count == 8)
        #expect(!harness.frames.coalescer.hasPending)
    }
}
