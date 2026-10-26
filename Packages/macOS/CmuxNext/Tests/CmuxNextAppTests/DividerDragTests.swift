import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

/// Divider drags once per frame (feature `pointerFrameDrags`, p04-input-031): with the window's
/// frame-aligned input, a frame's drag events move the divider once, to the latest point (Chromium's
/// rAF-aligned input, `main_thread_event_queue.cc`), every event still feeds the release velocity,
/// and the release lands the frame's pending move first.
@MainActor @Suite(.serialized) struct DividerDragTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let scheduler: FrameScheduler
        let coalescer: FrameInputCoalescer
        /// The drag events the screen got, in order.
        var events: [DividerHandleView.DragEvent] = []
        var intents: [LayoutIntent] = []

        init() throws {
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
            scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in DividerDragFakeLink() }
            let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
            self.coalescer = coalescer
            root.dragFrameInput = FrameInputCoalescers(make: { _ in coalescer })
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

        var moves: Int {
            events.reduce(0) { count, event in
                guard case .moved = event else { return count }
                return count + 1
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

        func frame() { scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120) }

        func close() {
            coalescer.invalidate()
            window.close()
        }
    }

    /// Eight drag events in one frame move the divider at most twice (here once, at the frame), to
    /// the last event's point.
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
        #expect(harness.moves <= 2, "eight drag events moved the divider \(harness.moves) times")
        harness.frame()
        #expect(harness.moves >= 1 && harness.moves <= 2, "the frame moved the divider \(harness.moves) times")
        guard case let .moved(point, samples)? = harness.events.last else {
            Issue.record("the frame delivered no move: \(harness.events)")
            return
        }
        #expect(point == CGPoint(x: start.x - 80, y: start.y), "the move goes to the frame's latest point")
        #expect(samples.count == 8, "every event of the frame reaches the velocity")
        #expect(harness.ratio < before)
        #expect(harness.intents.isEmpty, "a drag is local until it ends")
    }

    /// The release velocity is the one every event gives, not the latest one alone: the frame's
    /// samples feed `DividerDragState.sample` in order, at their event times.
    @Test func everySampleFeedsTheReleaseVelocity() throws {
        let harness = try Harness()
        defer { harness.close() }
        let handle = try harness.handle
        let screen = try harness.screen
        let start = try harness.center()
        let t0 = CACurrentMediaTime() - 0.03
        handle.mouseDown(with: harness.event(.leftMouseDown, start, at: t0))
        let began = try #require(screen.activeDrag)
        var reference = began
        // Accelerating: a smoothed velocity over all eight differs from the last pair's.
        let points = (1...8).map { CGPoint(x: start.x - CGFloat($0 * $0) * 2, y: start.y) }
        for (index, point) in points.enumerated() {
            let time = t0 + Double(index + 1) * 0.002
            handle.mouseDragged(with: harness.event(.leftMouseDragged, point, at: time))
            reference.sample(screen.contentPoint(fromWindow: point, kind: .split("x")), at: time)
        }
        harness.frame()
        let drag = try #require(screen.activeDrag)
        #expect(drag.velocity == reference.velocity)
        #expect(drag.pointer?.position == reference.pointer?.position)
        #expect(drag.pointer?.time == reference.pointer?.time)
        var latestOnly = began
        latestOnly.sample(screen.contentPoint(fromWindow: points[6], kind: .split("x")), at: t0 + 0.014)
        latestOnly.sample(screen.contentPoint(fromWindow: points[7], kind: .split("x")), at: t0 + 0.016)
        #expect(drag.velocity != latestOnly.velocity, "the velocity used the whole frame's samples")
        // `releaseVelocity` reads only `velocity` and `pointer`, equal above: the release springs as per-event delivery did.
        handle.mouseUp(with: harness.event(.leftMouseUp, points[7], at: t0 + 0.017))
        #expect(screen.releasedDivider != nil)
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
        handle.mouseDragged(with: harness.event(.leftMouseDragged, end))
        handle.mouseUp(with: harness.event(.leftMouseUp, end))
        let kinds = harness.events.map { event -> String in
            switch event {
            case .began: "began"
            case .moved: "moved"
            case .ended: "ended"
            case .doubleClick: "doubleClick"
            }
        }
        #expect(kinds == ["began", "moved", "ended"])
        #expect(!harness.coalescer.hasPending)
        let ended = harness.intents.compactMap { intent -> Double? in
            if case let .setSplitRatio(_, ratio, _, .ended) = intent { return ratio }
            return nil
        }
        #expect(ended.count == 1)
        #expect(abs((ended.first ?? 0) - harness.ratio) < 1e-9)
        #expect((ended.first ?? 1) < 0.5)
    }

    /// With no frame-aligned input (the feature off), every drag event still moves the divider at once.
    @Test func withoutFrameInputEveryEventMovesTheDivider() throws {
        let harness = try Harness()
        defer { harness.close() }
        harness.root.dragFrameInput = nil
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        for step in 1...8 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 10, y: start.y)))
        }
        #expect(harness.moves == 8)
        #expect(!harness.coalescer.hasPending)
    }
}

@MainActor
private final class DividerDragFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
