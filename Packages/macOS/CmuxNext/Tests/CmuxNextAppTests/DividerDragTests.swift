import AppKit
@testable import CmuxNextBrowser
import CmuxNextInputCore
@testable import CmuxNextLayout
import CmuxNextWakeups
import QuartzCore
import Testing

/// Divider drags at most twice per frame (feature `pointerFrameDrags`): with the
/// window's FrameInputCoalescer the first drag event of a frame interval moves the
/// divider in its own turn and the rest move it once more at the frame, to the latest point
/// (Chromium's rAF-aligned input, `main_thread_event_queue.cc`); every event still feeds the release
/// velocity at its own timestamp, and the release lands the pending move first.
@MainActor @Suite(.serialized) struct DividerDragTests {
    final class Panes: LayoutPaneContentProvider {
        let content: (PaneID) -> NSView
        init(content: @escaping (PaneID) -> NSView) { self.content = content }
        func makeContentView(for pane: PaneID) -> NSView { content(pane) }
    }

    /// A browser pane's omnibar across its pane's width: resized on every frame of a divider drag beside it,
    /// laid out again each time as the browser chrome's constraints lay it out.
    final class OmnibarPane: NSView {
        let bar = AddressBarView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(bar)
            bar.update(url: URL(string: "https://example.com/some/path?query=1"), security: .none)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            bar.frame = NSRect(x: 8, y: 8, width: max(0, newSize.width - 16), height: 34)
            bar.needsLayout = true
        }
    }

    final class Harness {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: CursorRectCountingWindow
        let frames = PointerFrameTestRig()
        /// The drag events the screen got, in order.
        var events: [DividerHandleView.DragEvent] = []
        var intents: [LayoutIntent] = []

        /// `coalesced`: the drags go through the window's coalescer (the feature on). `resampled`: the
        /// divider is drawn at the pointer resampled at the frame. `reduceMotion` pins the
        /// layout's Reduce Motion (nil follows the app).
        /// `content`: each pane's view (a plain view by default).
        init(coalesced: Bool = true, resampled: Bool = false, reduceMotion: Bool? = nil,
             content: @escaping (PaneID) -> NSView = { _ in NSView() }) throws {
            _ = NSApplication.shared
            provider = Panes(content: content)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s",
                                                       layout: .splits(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = CursorRectCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.setDragInput(frames: coalesced ? frames.coalescers : nil, resampler: { resampled ? DragResampler() : nil })
            root.context.reduceMotionOverride = reduceMotion
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
        guard case let .moved(point, _, _)? = harness.events.last else {
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

    // MARK: Resampled visuals

    /// 1/256 s between drag events: exact in binary and over Chromium's kResampleMinDelta (2 ms). The rig's
    /// frame n is at 1000 + n/120 s, so three events from 1000 s come before frame 1.
    static let step = 1.0 / 256

    /// Drags `harness` through `points`, three events per frame from 1000 s, one rig frame after each
    /// three; `release` lets go at the last point after the last frame.
    static func drag(_ harness: Harness, through points: [CGPoint], release: Bool) throws {
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start, at: 1000 - step))
        for (index, point) in points.enumerated() {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, point, at: 1000 + Double(index) * step))
            if index % 3 == 2 { harness.frames.frame() }
        }
        guard release, let last = points.last else { return }
        handle.mouseUp(with: harness.event(.leftMouseUp, last, at: 1000 + Double(points.count) * step))
    }

    /// The last move's real point and the point it was drawn at.
    static func lastMove(_ harness: Harness) -> (real: CGPoint, shown: CGPoint?)? {
        for event in harness.events.reversed() {
            if case let .moved(point, _, shown) = event { return (point, shown) }
        }
        return nil
    }

    static func endedRatio(_ harness: Harness) -> Double? {
        harness.intents.lazy.compactMap { intent -> Double? in
            if case let .setSplitRatio(_, ratio, _, .ended) = intent { return ratio }
            return nil
        }.first
    }

    /// A frame's move hands the screen the real pointer and draws the divider at the pointer resampled
    /// at the frame's time: 5 ms behind it (kResampleLatency), so it trails the real pointer.
    @Test func aFrameDrawsTheDividerAtTheResampledPointer() throws {
        let resampled = try Harness(resampled: true, reduceMotion: false)
        defer { resampled.close() }
        let plain = try Harness(resampled: false, reduceMotion: false)
        defer { plain.close() }
        let start = try resampled.center()
        let points = (1...3).map { CGPoint(x: start.x - CGFloat($0) * 20, y: start.y) }
        for harness in [resampled, plain] { try Self.drag(harness, through: points, release: false) }

        let move = try #require(Self.lastMove(resampled))
        let plainMove = try #require(Self.lastMove(plain))
        #expect(move.real == points[2], "the screen gets the real pointer")
        #expect(plainMove.real == move.real)
        #expect(plainMove.shown == nil, "no resampler: drawn at the real pointer")
        let shown = try #require(move.shown, "the frame's move is resampled")
        #expect(shown.x > move.real.x, "5 ms behind a leftward drag: right of the real pointer")
        #expect(shown.y == move.real.y)
        #expect(resampled.ratio > plain.ratio, "the drawn divider trails the real pointer")
        let screen = try resampled.screen
        let plainScreen = try plain.screen
        #expect(screen.activeDrag?.pointer?.position == plainScreen.activeDrag?.pointer?.position,
                "the velocity samples are the real points")
        #expect(screen.activeDrag?.velocity == plainScreen.activeDrag?.velocity)
    }

    /// Resampling moves only what is drawn: the same events land on the same ratio, with the same release
    /// velocity, with the resampler on and off.
    @Test func theDropIsTheSameWithResamplingOnAndOff() throws {
        let resampled = try Harness(resampled: true, reduceMotion: false)
        defer { resampled.close() }
        let plain = try Harness(resampled: false, reduceMotion: false)
        defer { plain.close() }
        let start = try resampled.center()
        // Accelerating, so a drawn point off the real one would change the ratio.
        let points = (1...9).map { CGPoint(x: start.x - CGFloat($0 * $0) * 2, y: start.y) }
        for harness in [resampled, plain] { try Self.drag(harness, through: points, release: true) }

        #expect(resampled.events.contains { event in
            if case .moved(_, _, .some(_)) = event { return true }
            return false
        }, "the drag was drawn resampled")
        let ended = try #require(Self.endedRatio(resampled))
        let plainEnded = try #require(Self.endedRatio(plain))
        #expect(ended == plainEnded)
        #expect(resampled.ratio == plain.ratio)
        let released = try #require(try resampled.screen.releasedDivider)
        let plainReleased = try #require(try plain.screen.releasedDivider)
        #expect(released.velocity == plainReleased.velocity)
    }

    /// A snap is decided at the real pointer: a divider whose real pointer reaches the halfway snap lands
    /// there though the drawn point still trails outside the snap distance.
    @Test func aSnapIsDecidedAtTheRealPointer() throws {
        let resampled = try Harness(resampled: true, reduceMotion: false)
        defer { resampled.close() }
        let plain = try Harness(resampled: false, reduceMotion: false)
        defer { plain.close() }
        let start = try resampled.center()
        let points = [-60.0, -40, -3].map { CGPoint(x: start.x + $0, y: start.y) }
        for harness in [resampled, plain] { try Self.drag(harness, through: points, release: false) }

        let shown = try #require(Self.lastMove(resampled)?.shown)
        #expect(start.x - shown.x > DividerDragState.snapDistance, "the drawn point is outside the snap")
        #expect(plain.ratio == 0.5, "the real pointer is within the snap")
        #expect(resampled.ratio == 0.5, "the snap reads the real pointer")
        #expect(try resampled.screen.activeDrag?.snapped == 0.5)
    }

    /// A frame tick that main runs after a leading edge, though its vsync came before that edge's event, never
    /// draws the divider back against the drag: the drag's resample time does not go back.
    @Test func aLateTickNeverDrawsTheDividerBack() throws {
        let harness = try Harness(resampled: true, reduceMotion: false)
        defer { harness.close() }
        let handle = try harness.handle
        let start = try harness.center()
        // A leftward drag at 10 points per step: event i at 1000 + i * step, 10 * (i + 1) points left of the start.
        func drag(_ index: Int) {
            let point = CGPoint(x: start.x - CGFloat(10 * (index + 1)), y: start.y)
            handle.mouseDragged(with: harness.event(.leftMouseDragged, point, at: 1000 + Double(index) * Self.step))
        }
        handle.mouseDown(with: harness.event(.leftMouseDown, start, at: 1000 - Self.step))
        for index in 0...2 { drag(index) }
        harness.frames.frame()
        // Event 5 (1000.0195 s) is the next interval's leading edge; the next tick's vsync is 1000.0167 s.
        for index in 5...7 { drag(index) }
        harness.frames.frame()
        let shown = harness.events.compactMap { event -> CGPoint? in
            if case let .moved(_, _, shown) = event { return shown }
            return nil
        }
        #expect(shown.count == 4, "two leading edges and two frames: \(harness.kinds)")
        let leading = try #require(shown.dropLast().last)
        let trailing = try #require(shown.last)
        #expect(trailing.x <= leading.x + 1e-6, "the divider went back: \(leading.x) then \(trailing.x)")
    }

    /// Reduce Motion draws the divider at the real pointer whatever the resampler setting.
    @Test func reduceMotionDrawsTheRealPointer() throws {
        let reduced = try Harness(resampled: true, reduceMotion: true)
        defer { reduced.close() }
        let plain = try Harness(resampled: false, reduceMotion: true)
        defer { plain.close() }
        let start = try reduced.center()
        let points = (1...3).map { CGPoint(x: start.x - CGFloat($0) * 20, y: start.y) }
        for harness in [reduced, plain] { try Self.drag(harness, through: points, release: false) }

        let move = try #require(Self.lastMove(reduced))
        #expect(move.shown == nil)
        #expect(reduced.ratio == plain.ratio)
    }

    // MARK: Cursor

    /// A 20-frame drag invalidates none of the window's cursor rects: the handle and the panes set their
    /// cursors when the pointer enters (`cursorUpdate`), so the handle's frame moving every frame (here
    /// once per frame on top of the drag's own layout) rebuilds nothing. The pane beside the divider is a
    /// browser's omnibar, resized on every frame: before, its layout invalidated its region cursor rects
    /// on each width change (the text area moved).
    @Test func aTwentyFrameDragInvalidatesNoCursorRects() throws {
        var omnibars: [OmnibarPane] = []
        let harness = try Harness { _ in
            let view = OmnibarPane(frame: .zero)
            omnibars.append(view)
            return view
        }
        defer { harness.close() }
        #expect(omnibars.count == 2, "both panes are browser panes")
        let bars = omnibars.map(\.bar)
        let widths = bars.map(\.frame.width)
        let handle = try harness.handle
        let start = try harness.center()
        harness.root.layoutSubtreeIfNeeded()
        let before = harness.window.cursorRectInvalidations
        let ratio = harness.ratio
        handle.mouseDown(with: harness.event(.leftMouseDown, start, at: 1000))
        for frame in 1...20 {
            let point = CGPoint(x: start.x - CGFloat(frame) * 5, y: start.y)
            handle.mouseDragged(with: harness.event(.leftMouseDragged, point, at: 1000 + Double(frame) / 120))
            harness.frames.frame()
            harness.root.layoutSubtreeIfNeeded()
            handle.frame = handle.frame.offsetBy(dx: -1, dy: 0)
        }
        handle.mouseUp(with: harness.event(.leftMouseUp, CGPoint(x: start.x - 100, y: start.y), at: 1000 + 21.0 / 120))
        #expect(harness.moves >= 20, "every frame moved the divider: \(harness.kinds)")
        #expect(harness.ratio < ratio)
        #expect(bars.map(\.frame.width) != widths, "the drag resized the omnibars")
        #expect(harness.window.cursorRectInvalidations == before,
                "cursor rects invalidated during the drag: \(harness.window.invalidatedViews.dropFirst(before))")
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
