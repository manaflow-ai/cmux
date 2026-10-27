import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The DevTools divider at most twice per frame (feature `pointerFrameDrags`, p04-input-031): with
/// the window's FrameInputCoalescer (p04-input-030) the first drag event of a frame interval moves
/// the line in its own turn and the rest once more at the frame, to the latest point (Chromium's
/// rAF-aligned input, `main_thread_event_queue.cc`); the release lands the pending move first.
@MainActor @Suite(.serialized) struct CEFDevToolsDividerTests {
    final class Harness {
        let divider = CEFDevToolsDivider(frame: NSRect(x: 0, y: 300, width: 800, height: 6))
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        var moves: [CGPoint] = []
        private var frames = 0

        /// `coalesced`: the drags go through the window's coalescer (the feature on).
        init(coalesced: Bool = true) {
            _ = NSApplication.shared
            let ledger = WakeupLedger()
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in DevToolsDividerTestLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
            self.coalescer = coalescer
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 640))
            host.addSubview(divider)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            divider.pointerFrames = coalesced ? FrameInputCoalescers { _ in coalescer } : nil
            divider.onMove = { [unowned self] point in moves.append(point) }
        }

        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 400, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// One 120 Hz link frame: the coalescer's trailing deliveries run.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight drag events in one frame: the first moves the line at once, the other seven once at the frame.
    @Test func eightDragsInOneFrameMoveTheLineTwice() {
        let harness = Harness()
        defer { harness.close() }
        harness.divider.mouseDown(with: harness.event(.leftMouseDown, y: 303))
        for step in 1...8 {
            harness.divider.mouseDragged(with: harness.event(.leftMouseDragged, y: 303 + CGFloat(step) * 4))
        }
        #expect(harness.moves.map(\.y) == [307], "the leading drag moved the line in its own turn")
        harness.frame()
        #expect(harness.moves.map(\.y) == [307, 335], "the frame moved it once more, to the latest point")
    }

    /// The release lands the pending move before the drag ends, and nothing lands after it.
    @Test func theReleaseFlushesThePendingMoveFirst() {
        let harness = Harness()
        defer { harness.close() }
        harness.divider.mouseDown(with: harness.event(.leftMouseDown, y: 303))
        harness.divider.mouseDragged(with: harness.event(.leftMouseDragged, y: 310))
        harness.divider.mouseDragged(with: harness.event(.leftMouseDragged, y: 320))
        harness.divider.mouseUp(with: harness.event(.leftMouseUp, y: 320))
        #expect(harness.moves.map(\.y) == [310, 320])
        #expect(!harness.coalescer.hasPending)
        harness.frame()
        #expect(harness.moves.count == 2)
    }

    /// The line is a layer strip, never a backing store: hidden with no DevTools, a vertical strip for a
    /// side dock and a horizontal one for the bottom dock, centered in the grab area, and placed
    /// again when the divider is resized.
    @Test func theLineIsALayerStripForTheDockSide() {
        _ = NSApplication.shared
        let thickness = CEFDevToolsLayout.lineThickness
        let divider = CEFDevToolsDivider(frame: NSRect(x: 0, y: 0, width: 7, height: 400))
        #expect(divider.wantsUpdateLayer)
        divider.updateLayer()
        #expect(divider.line.isHidden, "no DevTools, no line")

        let side = CEFDevToolsController(layout: CEFDevToolsLayout())
        side.layout.dock = .right
        withExtendedLifetime(side) {
            divider.devTools = side
            divider.updateLayer()
            #expect(!divider.line.isHidden)
            #expect(divider.line.backgroundColor != nil)
            #expect(divider.line.frame == NSRect(x: 3.5 - thickness / 2, y: 0, width: thickness, height: 400))
            divider.setFrameSize(NSSize(width: 7, height: 520))
            #expect(divider.line.frame == NSRect(x: 3.5 - thickness / 2, y: 0, width: thickness, height: 520),
                    "the line follows the new height")
        }

        let bottom = CEFDevToolsController(layout: CEFDevToolsLayout())
        bottom.layout.dock = .bottom
        withExtendedLifetime(bottom) {
            divider.devTools = bottom
            divider.setFrameSize(NSSize(width: 800, height: 7))
            divider.updateLayer()
            #expect(divider.line.frame == NSRect(x: 0, y: 3.5 - thickness / 2, width: 800, height: thickness))
            divider.setFrameSize(NSSize(width: 900, height: 7))
            #expect(divider.line.frame == NSRect(x: 0, y: 3.5 - thickness / 2, width: 900, height: thickness),
                    "the line follows the new width")
        }
        #expect(divider.layer?.contents == nil, "the divider draws no backing store")
    }

    /// With no frame-aligned input (the feature off), every drag event moves the line at once.
    @Test func withoutFrameInputEveryEventMovesTheLine() {
        let harness = Harness(coalesced: false)
        defer { harness.close() }
        harness.divider.mouseDown(with: harness.event(.leftMouseDown, y: 303))
        for step in 1...8 {
            harness.divider.mouseDragged(with: harness.event(.leftMouseDragged, y: 303 + CGFloat(step) * 4))
        }
        #expect(harness.moves.count == 8)
    }
}

@MainActor
private final class DevToolsDividerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
