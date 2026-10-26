import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import QuartzCore
import Testing

/// Divider drags at most twice per frame (feature `pointerFrameDrags`, p04-input-031): with the
/// window's FrameInputCoalescer (p04-input-030) the first drag event of a frame interval moves the
/// divider in its own turn and the rest move it once more at the frame, to the latest point
/// (Chromium's rAF-aligned input, `main_thread_event_queue.cc`); every event still feeds the release
/// velocity at its own timestamp, and the release lands the pending move first.
@MainActor @Suite(.serialized) struct DividerDragTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let frames = PointerFrameTestRig()
        /// The drag events the screen got, in order.
        var events: [DividerHandleView.DragEvent] = []
        var intents: [LayoutIntent] = []

        /// `coalesced`: the drags go through the window's coalescer (the feature on).
        init(coalesced: Bool = true) throws {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s",
                                                       layout: .splits(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.dragFrameInput = coalesced ? frames.coalescers : nil
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
            let divider = try self.handle
            let forward = divider.onDrag
            divider.onDrag = { [unowned self] event in
                events.append(event)
                forward?(event)
            }
        }

        var screen: ScreenContentView {
            get throws { try #require(root.screenViews["s"]) }
        }

        var handle: DividerHandleView {
            get throws { try #require(root.screenViews["s"]?.dividerViews[.split("x")]) }
        }

        /// Moves of the divider so far (each one `applyDrag` and one `setSplitRatio`).
        var moves: Int {
            events.reduce(0) { count, event in
                guard case .moved = event else { return count }
                return count + 1
            }
        }

        var kinds: [String] {
            events.map { event in
                switch event {
                case .began: "began"
                case .sampled: "sampled"
                case .moved: "moved"
                case .ended: "ended"
                case .doubleClick: "doubleClick"
                }
            }
        }

        var ratio: Double { model.screens[0].layout.ratio(of: "x") ?? 0 }

        func center() throws -> CGPoint {
            let handle = try handle
            return handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint, at time: TimeInterval = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// The first drag event after an idle frame moves the divider in its own turn: no frame waits
    /// between the pointer and the layout.
    @Test func theFirstDragMovesTheDividerInTheSameTurn() throws {
        let harness = try Harness()
        defer { harness.close() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        let before = harness.ratio
        handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - 40, y: start.y)))
        #expect(harness.moves == 1, "the leading drag moved the divider before any frame")
        #expect(harness.ratio < before)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// Eight drag events in one frame move the divider twice: the first at once, the other seven
    /// once at the frame, to the last event's point, with every point between for the velocity.
    @Test func eightDragsInOneFrameSetTheRatioAtMostTwice() throws {
        let harness = try Harness()
        defer { harness.close() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        let before = harness.ratio
        for step in 1...8 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 10, y: start.y)))
        }
        #expect(harness.moves == 1, "only the leading drag moved the divider before the frame")
        harness.frames.frame()
        #expect(harness.moves == 2, "eight drag events in a frame moved the divider \(harness.moves) times")
        guard case let .moved(point, _)? = harness.events.last else {
            Issue.record("the frame delivered no move: \(harness.kinds)")
            return
        }
        #expect(point == CGPoint(x: start.x - 80, y: start.y), "the move goes to the frame's latest point")
        #expect(harness.kinds == ["began", "moved"] + Array(repeating: "sampled", count: 6) + ["moved"],
                "every event of the frame reaches the velocity")
        #expect(harness.ratio < before)
        #expect(harness.intents.isEmpty, "a drag is local until it ends")
    }

    /// The coalesced path gives the same velocity and release velocity as per-event delivery for the
    /// same timestamped events, and the release reads the release event's time: a main thread that
    /// handles the release long after the events (a STRESS layout) still springs the divider on.
    @Test func everySampleFeedsTheReleaseVelocityOnTheEventsClock() throws {
        let coalesced = try Harness(coalesced: true)
        defer { coalesced.close() }
        let perEvent = try Harness(coalesced: false)
        defer { perEvent.close() }
        // Event times a second before they are handled: far past the 50 ms stillness window.
        let t0 = CACurrentMediaTime() - 1
        let start = try coalesced.center()
        let perEventStart = try perEvent.center()
        #expect(start == perEventStart)
        // Accelerating: a smoothed velocity over all eight differs from the last pair's.
        let points = (1...8).map { CGPoint(x: start.x - CGFloat($0 * $0) * 2, y: start.y) }
        for harness in [coalesced, perEvent] {
            let handle = try harness.handle
            handle.mouseDown(with: harness.event(.leftMouseDown, start, at: t0))
            for (index, point) in points.enumerated() {
                handle.mouseDragged(with: harness.event(.leftMouseDragged, point, at: t0 + Double(index + 1) * 0.002))
            }
            harness.frames.frame()
        }
        let screen = try coalesced.screen
        let referenceScreen = try perEvent.screen
        let drag = try #require(screen.activeDrag)
        let reference = try #require(referenceScreen.activeDrag)
        #expect(drag.velocity == reference.velocity)
        #expect(drag.pointer?.position == reference.pointer?.position)
        #expect(drag.pointer?.time == reference.pointer?.time)
        #expect(drag.pointer?.time == t0 + 0.016, "samples carry the events' own timestamps")
        #expect(drag.releaseVelocity(at: t0 + 0.017) == reference.releaseVelocity(at: t0 + 0.017))
        var latestOnly = drag
        latestOnly.velocity = 0
        latestOnly.pointer = nil
        latestOnly.sample(screen.contentPoint(fromWindow: points[6], kind: .split("x")), at: t0 + 0.014)
        latestOnly.sample(screen.contentPoint(fromWindow: points[7], kind: .split("x")), at: t0 + 0.016)
        #expect(drag.velocity != latestOnly.velocity, "the velocity used the whole frame's samples")

        for harness in [coalesced, perEvent] {
            try harness.handle.mouseUp(with: harness.event(.leftMouseUp, points[7], at: t0 + 0.017))
        }
        let released = try #require(screen.releasedDivider)
        let releasedReference = try #require(referenceScreen.releasedDivider)
        #expect(released.velocity != 0, "a release handled a second late still springs on")
        #expect(released.velocity == releasedReference.velocity)
        #expect(released.velocity == reference.velocity)
    }

    /// The release lands the frame's pending move before it ends the drag (Chromium's
    /// ShouldFlushQueue), so the saved ratio is the pointer's last one.
    @Test func theReleaseFlushesThePendingMoveFirst() throws {
        let harness = try Harness()
        defer { harness.close() }
        let handle = try harness.handle
        let start = try harness.center()
        let end = CGPoint(x: start.x - 200, y: start.y)
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - 100, y: start.y)))
        handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - 150, y: start.y)))
        handle.mouseDragged(with: harness.event(.leftMouseDragged, end))
        handle.mouseUp(with: harness.event(.leftMouseUp, end))
        #expect(harness.kinds == ["began", "moved", "sampled", "moved", "ended"])
        #expect(!harness.frames.coalescer.hasPending)
        let ended = harness.intents.compactMap { intent -> Double? in
            if case let .setSplitRatio(_, ratio, _, .ended) = intent { return ratio }
            return nil
        }
        #expect(ended.count == 1)
        #expect(abs((ended.first ?? 0) - harness.ratio) < 1e-9)
        #expect((ended.first ?? 1) < 0.5)
        harness.frames.frame()
        #expect(harness.kinds.last == "ended", "nothing lands after the release")
    }

    /// With no frame-aligned input (the feature off), every drag event still moves the divider at once.
    @Test func withoutFrameInputEveryEventMovesTheDivider() throws {
        let harness = try Harness(coalesced: false)
        defer { harness.close() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        for step in 1...8 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 10, y: start.y)))
        }
        #expect(harness.moves == 8)
        #expect(!harness.frames.coalescer.hasPending)
    }
}
