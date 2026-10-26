import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The sidebar's resize edge once per frame (feature `pointerFrameDrags`, p04-input-031): with the
/// window's frame-aligned input, a frame's drag events resize the sidebar once, to the latest point,
/// and the release lands the pending resize first.
@MainActor @Suite(.serialized) struct SidebarResizeHandleTests {
    final class Harness {
        let model = SidebarModel()
        let container: SidebarContainerView
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
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
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in SidebarResizeFakeLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
            self.coalescer = coalescer
            container.resizeFrameInput = FrameInputCoalescers(make: { _ in coalescer })
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

        func frame() { scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120) }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight drag events in one frame resize the sidebar at most twice, to the last event's width.
    @Test func eightDragsInOneFrameResizeAtMostTwice() {
        let harness = Harness()
        defer { harness.close() }
        let startWidth = harness.model.width
        let startX: CGFloat = 200
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        for step in 1...8 {
            harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + CGFloat(step) * 2))
        }
        #expect(harness.changes.count <= 2)
        harness.frame()
        #expect(harness.changes.count >= 1 && harness.changes.count <= 2, "the frame resized \(harness.changes.count) times")
        #expect(harness.changes.last == 16)
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
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX + 12))
        harness.handle.mouseUp(with: harness.event(.leftMouseUp, x: startX + 12))
        #expect(harness.phases == ["began", "changed", "ended"])
        #expect(harness.model.width == startWidth + 12)
        #expect(!harness.coalescer.hasPending)
    }

    /// A pending resize that hides the sidebar ends the drag: the release sends no second end.
    @Test func aFlushedResizeThatHidesTheSidebarEndsTheDrag() {
        let harness = Harness()
        defer { harness.close() }
        let startX: CGFloat = 400
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 380))
        harness.handle.mouseUp(with: harness.event(.leftMouseUp, x: startX - 380))
        #expect(harness.model.presentation == .hidden)
        #expect(harness.phases == ["began", "changed"])
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
        #expect(!harness.coalescer.hasPending)
    }
}

@MainActor
private final class SidebarResizeFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
