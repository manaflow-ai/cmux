import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// An extension action's reorder drag on its window's drag frames (``PointerFrameDrag``, feature `pointerFrameDrags`):
/// the drag's start past 3 pt offsets on its own event; after it, a frame interval's first event
/// offsets the pinned buttons at once and the rest once at the frame, at the latest point, as Chromium delivers
/// rAF-aligned moves (main_thread_event_queue.cc); the release lands the pending offset before the drop.
@MainActor @Suite(.serialized) struct ExtensionActionButtonFrameDragTests {
    final class DragFramesWindow: NSWindow, DragFrameInputHosting {
        var dragFrameInput: FrameInputCoalescers?
    }

    final class Harness {
        let frames = FrameInputTestRig()
        let window = DragFramesWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        let button = ExtensionActionButton(actionID: "ext")
        var moves: [CGFloat] = []
        var ends: [CGFloat] = []

        init(frames on: Bool = true) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            if on { window.dragFrameInput = frames.coalescers }
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            window.contentView = content
            content.addSubview(button)
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: 100, y: 40, width: size.width, height: size.height)
            button.canDrag = { true }
            button.onDragMoved = { [unowned self] in moves.append($0) }
            button.onDragEnded = { [unowned self] in ends.append($0) }
        }

        func event(_ type: NSEvent.EventType, dx: CGFloat) throws -> NSEvent {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: center.x + dx, y: center.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func tearDown() {
            frames.close()
            window.close()
        }
    }

    @Test func eightDragEventsInOneFrameOffsetTheButtonsTwice() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.button.mouseDown(with: try h.event(.leftMouseDown, dx: 0))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: 10))
        #expect(h.moves == [10], "the drag's start offsets on its own event")
        for dx in stride(from: 20.0, through: 80.0, by: 10) { h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: dx)) }
        #expect(h.moves == [10, 20], "after the start, the frame's first event offsets at once and the rest wait")

        h.frames.frame()
        #expect(h.moves == [10, 20, 80])
        #expect(h.button.dragMoves.maxDeliveriesPerFrame <= 2)
    }

    @Test func theReleaseLandsThePendingOffsetBeforeTheDrop() throws {
        let h = Harness()
        defer { h.tearDown() }
        h.button.mouseDown(with: try h.event(.leftMouseDown, dx: 0))
        for dx in [10.0, 20, 40, 60] { h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: dx)) }
        h.button.mouseUp(with: try h.event(.leftMouseUp, dx: 60))
        #expect(h.moves == [10, 20, 60])
        #expect(h.ends == [60])
        #expect(!h.frames.coalescer.hasPending)
    }

    @Test func withoutDragFramesEveryEventOffsets() throws {
        let h = Harness(frames: false)
        defer { h.tearDown() }
        h.button.mouseDown(with: try h.event(.leftMouseDown, dx: 0))
        for dx in [10.0, 20, 40, 60] { h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: dx)) }
        #expect(h.moves == [10, 20, 40, 60])
    }
}
