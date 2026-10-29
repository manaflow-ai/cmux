import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Screenshot Section's drag on frame-aligned input (feature `pointerFrameDrags`): the rect
/// follows a frame interval's first drag event at once and the rest once at the frame, at the latest point
/// (Chromium's rAF-aligned moves); the release lands the pending point first, so the selection equals the
/// per-event one.
@MainActor @Suite(.serialized) struct BrowserSectionOverlayFramesTests {
    final class Harness {
        let frames = FrameInputTestRig()
        let view: BrowserSectionOverlayView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var finished: [BrowserSectionSelection?] = []

        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            view = BrowserSectionOverlayView(size: CGSize(width: 400, height: 300), pointerFrames: frameInput ? frames.coalescers : nil)
            window.contentView = view
            view.onFinish = { [unowned self] in finished.append($0) }
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func tearDown() {
            frames.close()
            window.close()
        }
    }

    @Test func eightDragsInOneFrameMoveTheRectTwice() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        view.mouseDown(with: try harness.event(.leftMouseDown, CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 50, y: 40)))
        #expect(view.selection.rect == CGRect(x: 10, y: 10, width: 40, height: 30), "the frame's first drag moves the rect at once")

        for step in 1...7 {
            view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 50 + 10 * Double(step), y: 40 + 5 * Double(step))))
        }
        #expect(view.selection.rect == CGRect(x: 10, y: 10, width: 40, height: 30), "later drags wait for the frame")

        harness.frames.frame()
        #expect(view.selection.rect == CGRect(x: 10, y: 10, width: 110, height: 65), "the frame moves it to the latest point")
    }

    @Test func theReleaseLandsThePendingPointFirst() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        view.mouseDown(with: try harness.event(.leftMouseDown, CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 30, y: 30)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 90, y: 80)))
        view.mouseUp(with: try harness.event(.leftMouseUp, CGPoint(x: 90, y: 80)))

        #expect(harness.finished.count == 1)
        #expect(harness.finished.first??.rect == CGRect(x: 20, y: 20, width: 70, height: 60))
        #expect(!harness.frames.coalescer.hasPending, "nothing waits after the release")
    }

    @Test func withoutFramesEveryDragMovesTheRect() throws {
        let harness = Harness(frameInput: false)
        defer { harness.tearDown() }
        let view = harness.view
        view.mouseDown(with: try harness.event(.leftMouseDown, CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 50, y: 40)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 70, y: 60)))
        #expect(view.selection.rect == CGRect(x: 10, y: 10, width: 60, height: 50))
    }

    @Test func cancellingMidDragDropsThePendingPoint() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let view = harness.view
        view.mouseDown(with: try harness.event(.leftMouseDown, CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 50, y: 40)))
        view.mouseDragged(with: try harness.event(.leftMouseDragged, CGPoint(x: 90, y: 90)))
        view.cancelOperation(nil)
        harness.frames.frame()

        #expect(harness.finished.count == 1 && harness.finished.first.flatMap { $0 } == nil, "Esc answers nil")
        #expect(view.selection.rect == CGRect(x: 10, y: 10, width: 40, height: 30), "the pending point never lands after Esc")
    }
}
