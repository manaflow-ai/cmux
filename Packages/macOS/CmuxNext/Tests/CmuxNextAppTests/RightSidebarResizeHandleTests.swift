import AppKit
@testable import CmuxNextApp
import Testing

/// The right sidebar's resize edge at most twice per frame (feature `pointerFrameDrags`):
/// the first drag event of a frame interval resizes in its own turn, the rest once
/// more at the frame, to the latest point; the release lands the pending resize first.
@MainActor @Suite(.serialized) struct RightSidebarResizeHandleTests {
    final class Harness {
        let handle = RightSidebarResizeHandle(frame: NSRect(x: 600, y: 0, width: RightSidebarResizeHandle.grabWidth, height: 640))
        let window: NSWindow
        let frames = PointerFrameTestRig()
        var phases: [String] = []
        var changes: [CGFloat] = []

        /// `coalesced`: the drags go through the window's coalescer (the feature on).
        init(coalesced: Bool = true) {
            _ = NSApplication.shared
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
            host.addSubview(handle)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            handle.pointerFrames = coalesced ? frames.coalescers : nil
            handle.onDrag = { [unowned self] phase in
                switch phase {
                case .began: phases.append("began")
                case let .changed(dx):
                    phases.append("changed")
                    changes.append(dx)
                case .ended: phases.append("ended")
                }
            }
        }

        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// Eight drag events in one frame: the first resizes at once, the other seven once at the frame.
    @Test func eightDragsInOneFrameResizeTwice() {
        let harness = Harness()
        defer { harness.close() }
        let startX: CGFloat = 602
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        for step in 1...8 {
            harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - CGFloat(step) * 3))
        }
        #expect(harness.changes == [-3], "the leading drag resized in its own turn")
        harness.frames.frame()
        #expect(harness.changes == [-3, -24], "the frame resized once more, to the latest point")
    }

    /// The release lands the pending resize before the drag ends, and nothing lands after it.
    @Test func theReleaseFlushesThePendingResizeFirst() {
        let harness = Harness()
        defer { harness.close() }
        let startX: CGFloat = 602
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 5))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 9))
        harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - 12))
        harness.handle.mouseUp(with: harness.event(.leftMouseUp, x: startX - 12))
        #expect(harness.phases == ["began", "changed", "changed", "ended"])
        #expect(harness.changes == [-5, -12])
        #expect(!harness.frames.coalescer.hasPending)
        harness.frames.frame()
        #expect(harness.phases.last == "ended")
    }

    /// With no frame-aligned input (the feature off), every drag event resizes at once.
    @Test func withoutFrameInputEveryEventResizes() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        let startX: CGFloat = 602
        harness.handle.mouseDown(with: harness.event(.leftMouseDown, x: startX))
        for step in 1...8 {
            harness.handle.mouseDragged(with: harness.event(.leftMouseDragged, x: startX - CGFloat(step) * 3))
        }
        #expect(harness.changes.count == 8)
    }
}
