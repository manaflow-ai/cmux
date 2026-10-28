import AppKit
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A press's drag on its window's frame-aligned input (``PointerFrameDrag``): the frame interval's
/// first drag event moves at once and the rest once at the frame, at the latest point, as Chromium delivers
/// rAF-aligned moves (main_thread_event_queue.cc); the release lands the pending point first; a window without
/// drag frames moves on every event.
@MainActor @Suite(.serialized) struct PointerFrameDragTests {
    final class DragFramesWindow: NSWindow, DragFrameInputHosting {
        var dragFrameInput: FrameInputCoalescers?
    }

    final class Harness {
        let frames = FrameInputTestRig()
        let window = DragFramesWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var moves: [CGFloat] = []
        private(set) lazy var drag = PointerFrameDrag(owner: "PointerFrameDragTests", view: view) { [unowned self] point in
            moves.append(point.x)
        }

        init(frames on: Bool = true) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: view.frame)
            window.contentView?.addSubview(view)
            if on { window.dragFrameInput = frames.coalescers }
        }

        func dragged(_ x: Double) throws {
            drag.dragged(try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: CGPoint(x: x, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)))
        }

        func tearDown() {
            frames.close()
            window.close()
        }
    }

    @Test func eightDragEventsInOneFrameMoveTwiceToTheLatestPoint() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.drag.began()
        for x in stride(from: 10.0, through: 80.0, by: 10) { try h.dragged(x) }
        #expect(h.moves == [10], "the frame's first drag event moves at once, the rest wait")
        #expect(h.drag.hasPending)

        h.frames.frame()
        #expect(h.moves == [10, 80])
        #expect(h.drag.maxDeliveriesPerFrame <= 2)
        #expect(!h.drag.hasPending)
    }

    @Test func theReleaseLandsThePendingPointFirst() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.drag.began()
        for x in [10.0, 40, 70] { try h.dragged(x) }
        h.drag.ended()
        #expect(h.moves == [10, 70])
        #expect(!h.frames.coalescer.hasPending)
    }

    @Test func aNewPressDropsWhatTheLastOneLeft() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.drag.began()
        for x in [10.0, 40] { try h.dragged(x) }
        h.drag.began()
        h.frames.frame()
        #expect(h.moves == [10], "a point of the earlier press moved the new one")
        try h.dragged(90)
        #expect(h.moves == [10, 90], "the new press's first drag event is a leading edge")
    }

    @Test func aCancelDropsThePendingPoint() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.drag.began()
        for x in [10.0, 40] { try h.dragged(x) }
        h.drag.cancel()
        h.frames.frame()
        #expect(h.moves == [10])
    }

    @Test func withoutDragFramesEveryEventMoves() throws {
        let h = Harness(frames: false)
        defer { h.tearDown() }
        h.drag.began()
        for x in [10.0, 40, 70] { try h.dragged(x) }
        #expect(h.moves == [10, 40, 70])
    }

    @Test func aPointDeliveredAfterTheViewLeftItsWindowMovesNothing() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.drag.began()
        for x in [10.0, 40] { try h.dragged(x) }
        h.view.removeFromSuperview()
        h.frames.frame()
        #expect(h.moves == [10])
    }
}
