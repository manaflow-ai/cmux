import AppKit
import CmuxNextInput
@testable import CmuxNextLayout
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The layout's remaining per-event pointer sites at most twice per frame: a canvas pane
/// drag (`setCanvasFrame`), a canvas pan, the strip scrollbar's thumb drag (`onDrag`, feature
/// `pointerFrameDrags`) and the focus-follows-mouse hover (feature `pointerFrameHover`) take a frame
/// interval's first event in its own turn and the rest once at the frame, to the latest point, on the
/// window's FrameInputCoalescer (Chromium's rAF-aligned input,
/// `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). The state after the
/// release equals what one move per event left, the release lands the pending move first, and a thumb
/// drag's release velocity reads every point at its event's time.
@MainActor @Suite(.serialized) struct LayoutPointerCoalescingTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A window that carries hover frames (``HoverFrameInputHosting``), as the App's main windows do.
    final class HoverWindow: NSWindow, HoverFrameInputHosting {
        var hoverFrameInput: FrameInputCoalescers?
    }

    static let dragCount = 8

    static func window(frames: FrameInputCoalescers? = nil) -> HoverWindow {
        _ = NSApplication.shared
        let window = HoverWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hoverFrameInput = frames
        return window
    }

    static func event(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow, at time: TimeInterval = 0) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1)!
    }

    // MARK: Canvas

    /// Two panes shown as a canvas in a 1200 x 800 window; `coalesced` hands the layout the window's
    /// coalescers (the feature on).
    final class Canvas {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: HoverWindow
        let frames = FrameInputTestRig()

        init(coalesced: Bool) {
            let tree = SplitNode.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "a")
            root = LayoutRootView(model: model, contentProvider: panes, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = LayoutPointerCoalescingTests.window()
            root.context.reduceMotionOverride = true
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.setDragInput(frames: coalesced ? frames.coalescers : nil, resampler: { nil })
            _ = model.toggleCanvas(seed: ["a": CGRect(x: 100, y: 100, width: 400, height: 300),
                                          "b": CGRect(x: 650, y: 100, width: 400, height: 300)],
                                   viewport: CGSize(width: 1200, height: 800))
            root.syncWithModel()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
        var paneFrame: CGRect? { model.canvases["s"]?.frames["a"] }
        var shownCamera: CanvasCamera { screen.canvasState.camera.shown }

        /// Pane `a`'s move band (just above it), in window coordinates.
        func moveBand() throws -> CGPoint {
            let frame = try #require(paneFrame, "the canvas has pane a")
            return screen.convert(CGPoint(x: frame.midX, y: frame.minY - ScreenCanvasState.handleThickness / 2), to: nil)
        }

        /// Empty canvas below both panes, in window coordinates.
        func emptyCanvas() throws -> CGPoint {
            let frame = try #require(paneFrame)
            return screen.convert(CGPoint(x: frame.midX, y: frame.maxY + 150), to: nil)
        }

        func press(_ point: CGPoint) { screen.mouseDown(with: LayoutPointerCoalescingTests.event(.leftMouseDown, point, in: window)) }
        func drag(_ point: CGPoint) { screen.mouseDragged(with: LayoutPointerCoalescingTests.event(.leftMouseDragged, point, in: window)) }
        func release(_ point: CGPoint) { screen.mouseUp(with: LayoutPointerCoalescingTests.event(.leftMouseUp, point, in: window)) }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// The `step`th drag point of a run from `start`: down and to the right, 12 points a step.
    static func dragPoint(_ start: CGPoint, _ step: Int) -> CGPoint {
        CGPoint(x: start.x + CGFloat(step) * 12, y: start.y - CGFloat(step) * 7)
    }

    /// Eight drag events in one frame move the pane twice: the first in its own turn, the other seven once
    /// at the frame, to the last point; the release leaves it where one move per event did.
    @Test func eightCanvasPaneDragsInAFrameSetTheFrameAtMostTwice() throws {
        let canvas = Canvas(coalesced: true)
        defer { canvas.close() }
        let start = try canvas.moveBand()
        let before = try #require(canvas.paneFrame)
        canvas.press(start)
        let consumer = try #require(canvas.screen.canvasState.dragFrames, "the drag posts to the window's coalescer")
        canvas.drag(Self.dragPoint(start, 1))
        let leading = try #require(canvas.paneFrame)
        #expect(leading != before, "the leading drag moved the pane before any frame")
        for step in 2...Self.dragCount { canvas.drag(Self.dragPoint(start, step)) }
        #expect(canvas.paneFrame == leading, "drags after the leading one wait for the frame")
        #expect(consumer.deliveries == 1)
        canvas.frames.frame()
        #expect(consumer.deliveries == 2, "eight drags in a frame set the canvas frame \(consumer.deliveries) times")
        #expect(consumer.maxDeliveriesPerFrame <= 2)
        canvas.release(Self.dragPoint(start, Self.dragCount))
        #expect(canvas.screen.canvasState.dragFrames == nil, "the release lets go of the consumer")

        let perEvent = Canvas(coalesced: false)
        defer { perEvent.close() }
        perEvent.press(start)
        #expect(perEvent.screen.canvasState.dragFrames == nil, "without the coalescers each drag moves at once")
        for step in 1...Self.dragCount { perEvent.drag(Self.dragPoint(start, step)) }
        perEvent.release(Self.dragPoint(start, Self.dragCount))
        #expect(canvas.paneFrame == perEvent.paneFrame, "coalesced \(String(describing: canvas.paneFrame)), per event \(String(describing: perEvent.paneFrame))")
    }

    /// A release right after the drags, with no frame between, lands the pending move first.
    @Test func aReleaseLandsTheCanvasPanesPendingMove() throws {
        let canvas = Canvas(coalesced: true)
        defer { canvas.close() }
        let start = try canvas.moveBand()
        canvas.press(start)
        for step in 1...Self.dragCount { canvas.drag(Self.dragPoint(start, step)) }
        canvas.release(Self.dragPoint(start, Self.dragCount))
        #expect(!canvas.frames.coalescer.hasPending, "the release flushed the drag")

        let perEvent = Canvas(coalesced: false)
        defer { perEvent.close() }
        perEvent.press(start)
        for step in 1...Self.dragCount { perEvent.drag(Self.dragPoint(start, step)) }
        perEvent.release(Self.dragPoint(start, Self.dragCount))
        #expect(canvas.paneFrame == perEvent.paneFrame)
    }

    /// Eight pan drags in a frame move the camera twice, and the release reports the camera one move per
    /// event would have.
    @Test func eightCanvasPanDragsInAFrameMoveTheCameraAtMostTwice() throws {
        let canvas = Canvas(coalesced: true)
        defer { canvas.close() }
        let start = try canvas.emptyCanvas()
        let before = canvas.shownCamera
        canvas.press(start)
        let consumer = try #require(canvas.screen.canvasState.dragFrames)
        canvas.drag(Self.dragPoint(start, 1))
        let leading = canvas.shownCamera
        #expect(leading != before, "the leading drag panned before any frame")
        for step in 2...Self.dragCount { canvas.drag(Self.dragPoint(start, step)) }
        #expect(canvas.shownCamera == leading, "pans after the leading one wait for the frame")
        canvas.frames.frame()
        #expect(consumer.deliveries == 2, "eight pan drags in a frame moved the camera \(consumer.deliveries) times")
        canvas.release(Self.dragPoint(start, Self.dragCount))

        let perEvent = Canvas(coalesced: false)
        defer { perEvent.close() }
        perEvent.press(start)
        for step in 1...Self.dragCount { perEvent.drag(Self.dragPoint(start, step)) }
        perEvent.release(Self.dragPoint(start, Self.dragCount))
        #expect(canvas.shownCamera == perEvent.shownCamera)
        #expect(canvas.model.canvases["s"]?.camera == perEvent.model.canvases["s"]?.camera, "the release reports the same camera")
    }

    /// The screen leaving canvas mode mid-drag drops the pending move: nothing lands on a canvas that is gone.
    @Test func leavingCanvasModeDropsThePendingDrag() throws {
        let canvas = Canvas(coalesced: true)
        defer { canvas.close() }
        let start = try canvas.moveBand()
        canvas.press(start)
        for step in 1...3 { canvas.drag(Self.dragPoint(start, step)) }
        #expect(canvas.frames.coalescer.hasPending)
        _ = canvas.screen.updateCanvas(nil, animated: false)
        #expect(canvas.screen.canvasState.dragFrames == nil)
        #expect(!canvas.frames.coalescer.hasPending, "the pending drag went with the canvas")
    }

    // MARK: Strip scrollbar

    /// A strip scrollbar twice its viewport's width in a window; `coalesced` hands it the window's
    /// coalescers. `offsets` records every `onDrag`, `points` every `onDragSample` and `onDrag` with
    /// its time, `log` the order with the release.
    final class Scrollbar {
        struct Point: Equatable {
            var offset: CGFloat
            var time: TimeInterval
        }

        let window: HoverWindow
        let bar = StripScrollbarView(hideClock: ManualClock())
        let frames = FrameInputTestRig()
        var offsets: [CGFloat] = []
        var points: [Point] = []
        var log: [String] = []

        init(coalesced: Bool) {
            window = LayoutPointerCoalescingTests.window()
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            window.contentView = content
            content.addSubview(bar)
            if coalesced {
                let coalescers = frames.coalescers
                bar.pointerFrames = { coalescers }
            }
            bar.onDragSample = { [unowned self] offset, time in
                points.append(Point(offset: offset, time: time))
                log.append("sample")
            }
            bar.onDrag = { [unowned self] offset, time in
                offsets.append(offset)
                points.append(Point(offset: offset, time: time))
                log.append("drag")
            }
            bar.onDragEnded = { [unowned self] _ in log.append("ended") }
            let band = CGRect(x: 16, y: 0, width: 1168, height: StripScrollbarView.bandHeight)
            bar.update(StripScrollbarView.Input(mode: .always, band: band, offset: 0, contentWidth: 2400, viewportWidth: 1200,
                                                snaps: [0, 1200]), scrolled: true)
        }

        /// The thumb's center, in window coordinates.
        func thumbCenter() throws -> CGPoint {
            let thumb = try #require(bar.thumbRect, "a strip wider than its viewport has a thumb")
            return bar.convert(CGPoint(x: thumb.midX, y: thumb.midY), to: nil)
        }

        func press(_ point: CGPoint) { bar.mouseDown(with: LayoutPointerCoalescingTests.event(.leftMouseDown, point, in: window)) }
        /// The `step`th drag of a run, at its own event time.
        func drag(_ start: CGPoint, _ step: Int) {
            bar.mouseDragged(with: LayoutPointerCoalescingTests.event(.leftMouseDragged, LayoutPointerCoalescingTests.thumbPoint(start, step),
                                                                     in: window, at: LayoutPointerCoalescingTests.thumbTime(step)))
        }
        func release(_ point: CGPoint) { bar.mouseUp(with: LayoutPointerCoalescingTests.event(.leftMouseUp, point, in: window)) }

        func close() {
            frames.close()
            window.close()
        }
    }

    static func thumbPoint(_ start: CGPoint, _ step: Int) -> CGPoint { CGPoint(x: start.x + CGFloat(step) * 15, y: start.y) }
    /// The `step`th drag's event time: 4 ms apart (a 250 Hz mouse).
    static func thumbTime(_ step: Int) -> TimeInterval { 100 + TimeInterval(step) * 0.004 }

    /// Eight thumb drags in a frame scroll twice: the first at once, the rest at the frame to the last
    /// point, which is the offset one scroll per event reached. The six points between still reach the
    /// velocity, each with its own event time: the same points, at the same times, as one per event.
    @Test func eightThumbDragsInAFrameCallOnDragAtMostTwice() throws {
        let bar = Scrollbar(coalesced: true)
        defer { bar.close() }
        let start = try bar.thumbCenter()
        bar.press(start)
        bar.drag(start, 1)
        #expect(bar.offsets.count == 1, "the leading drag scrolled before any frame")
        for step in 2...Self.dragCount { bar.drag(start, step) }
        #expect(bar.offsets.count == 1, "drags after the leading one wait for the frame")
        bar.frames.frame()
        #expect(bar.offsets.count == 2, "eight thumb drags in a frame called onDrag \(bar.offsets.count) times")
        #expect(bar.log == ["drag"] + Array(repeating: "sample", count: Self.dragCount - 2) + ["drag"],
                "the frame's earlier points feed the velocity before the latest shows: \(bar.log)")
        bar.release(Self.thumbPoint(start, Self.dragCount))

        let perEvent = Scrollbar(coalesced: false)
        defer { perEvent.close() }
        perEvent.press(start)
        for step in 1...Self.dragCount { perEvent.drag(start, step) }
        perEvent.release(Self.thumbPoint(start, Self.dragCount))
        #expect(perEvent.offsets.count == Self.dragCount)
        #expect(bar.offsets.last == perEvent.offsets.last, "coalesced \(bar.offsets), per event \(perEvent.offsets)")
        #expect(bar.points == perEvent.points, "coalesced \(bar.points), per event \(perEvent.points)")
        #expect(perEvent.points.map(\.time) == (1...Self.dragCount).map(Self.thumbTime), "each point carries its event's time")
    }

    /// A release with drags pending scrolls to the last point before the drag ends.
    @Test func aReleaseLandsThePendingThumbDragBeforeItEnds() throws {
        let bar = Scrollbar(coalesced: true)
        defer { bar.close() }
        let start = try bar.thumbCenter()
        bar.press(start)
        for step in 1...Self.dragCount { bar.drag(start, step) }
        bar.release(Self.thumbPoint(start, Self.dragCount))
        #expect(bar.log == ["drag"] + Array(repeating: "sample", count: Self.dragCount - 2) + ["drag", "ended"],
                "the pending drag lands, then the drag ends: \(bar.log)")
        #expect(!bar.frames.coalescer.hasPending)

        let perEvent = Scrollbar(coalesced: false)
        defer { perEvent.close() }
        perEvent.press(start)
        for step in 1...Self.dragCount { perEvent.drag(start, step) }
        perEvent.release(Self.thumbPoint(start, Self.dragCount))
        #expect(bar.offsets.last == perEvent.offsets.last)
    }

    /// Three 0.6-wide columns in a 1200 x 800 window with the strip scrollbar always shown; `coalesced`
    /// hands the layout the window's coalescers (feature `pointerFrameDrags`).
    final class Strip {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: HoverWindow
        let frames = FrameInputTestRig()

        init(coalesced: Bool) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
                LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
                LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
                LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
            ]))], activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            model.stripScrollbarOverride = .always
            root = LayoutRootView(model: model, contentProvider: panes, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = LayoutPointerCoalescingTests.window()
            root.context.reduceMotionOverride = true
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.setDragInput(frames: coalesced ? frames.coalescers : nil, resampler: { nil })
            settle()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func settle() { for _ in 0..<600 where root.advanceFrame(1.0 / 120) {} }

        func bar() throws -> StripScrollbarView { try #require(screen.scrollbar, "a strip wider than its window has a scrollbar") }

        /// The thumb's center, in window coordinates.
        func thumbCenter() throws -> CGPoint {
            let bar = try bar()
            let thumb = try #require(bar.thumbRect, "the strip overflows: the bar has a thumb")
            return bar.convert(CGPoint(x: thumb.midX, y: thumb.midY), to: nil)
        }

        /// A slow drag that speeds up: twelve events 16 ms apart, 3 points a step, then 25 points a step
        /// for the last four. Longer than the reducer's 100 ms velocity window, so the release velocity
        /// depends on which points, at which times, it got. Coalesced, a frame comes after every fourth.
        static func flickPoint(_ start: CGPoint, _ step: Int) -> CGPoint {
            CGPoint(x: start.x + CGFloat(min(step, 8)) * 3 + CGFloat(max(step - 8, 0)) * 25, y: start.y)
        }
        static func flickTime(_ step: Int) -> TimeInterval { 200 + TimeInterval(step) * 0.016 }
        static let flickSteps = 12

        func press(_ point: CGPoint) throws {
            try bar().mouseDown(with: LayoutPointerCoalescingTests.event(.leftMouseDown, point, in: window, at: Self.flickTime(0)))
        }

        func drag(_ start: CGPoint, _ step: Int) throws {
            try bar().mouseDragged(with: LayoutPointerCoalescingTests.event(.leftMouseDragged, Self.flickPoint(start, step), in: window,
                                                                           at: Self.flickTime(step)))
        }

        func release(_ start: CGPoint) throws {
            let step = Self.flickSteps
            try bar().mouseUp(with: LayoutPointerCoalescingTests.event(.leftMouseUp, Self.flickPoint(start, step), in: window,
                                                                      at: Self.flickTime(step) + 0.004))
        }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// A thumb flick through the screen's scrollbar, delivered once per frame, reaches the scroll reducer
    /// as the same points at the same event times as one delivery per event: the release velocity, the
    /// snap column, the settled offset and the focus are equal.
    @Test func aCoalescedThumbFlickSettlesWhereOneScrollPerEventDoes() throws {
        let strip = Strip(coalesced: true)
        defer { strip.close() }
        let start = try strip.thumbCenter()
        try strip.press(start)
        for step in 1...Strip.flickSteps {
            try strip.drag(start, step)
            if step == 1 {
                #expect(strip.screen.scroll.value != 0, "the leading thumb drag scrolled before any frame")
            }
            if step.isMultiple(of: 4) { strip.frames.frame() }
        }
        #expect(!strip.frames.coalescer.hasPending)
        let gesture = try #require(strip.screen.scrollState.gesture, "the thumb drag holds the strip")

        let perEvent = Strip(coalesced: false)
        defer { perEvent.close() }
        try perEvent.press(start)
        for step in 1...Strip.flickSteps { try perEvent.drag(start, step) }
        let perEventGesture = try #require(perEvent.screen.scrollState.gesture)
        #expect(gesture.raw == perEventGesture.raw)
        #expect(gesture.samples == perEventGesture.samples,
                "the reducer's velocity samples: coalesced \(gesture.samples), per event \(perEventGesture.samples)")
        #expect(perEventGesture.samples.count > 2, "the velocity window holds several points")

        try strip.release(start)
        try perEvent.release(start)
        #expect(strip.screen.scrollState.spring.target == perEvent.screen.scrollState.spring.target, "the snap column")
        strip.settle()
        perEvent.settle()
        #expect(strip.screen.scroll.value == perEvent.screen.scroll.value,
                "settled coalesced at \(strip.screen.scroll.value), per event at \(perEvent.screen.scroll.value)")
        #expect(strip.model.focusedPane == perEvent.model.focusedPane)
    }

    // MARK: Focus follows mouse

    /// Two panes side by side with focus follows mouse on; `coalesced` gives the window hover frames.
    final class Hover {
        let panes = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window: HoverWindow
        let frames = FrameInputTestRig()

        init(coalesced: Bool) {
            let signals = ScrollFocusSignals(secondsSinceKeyDown: { 60 }, windowIsKey: { _ in true }, mouseButtonsDown: { false })
            root = LayoutRootView(model: model, contentProvider: panes, scrollFocusSignals: signals,
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = LayoutPointerCoalescingTests.window(frames: coalesced ? frames.coalescers : nil)
            model.focusFollowsMouseOverride = true
            root.context.reduceMotionOverride = true
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        func move(_ point: CGPoint) { root.mouseMoved(with: LayoutPointerCoalescingTests.event(.mouseMoved, point, in: window)) }

        func close() {
            frames.close()
            window.close()
        }
    }

    /// Eight moves in a frame, back and forth between the panes, resolve the hover twice: the first move in
    /// its own turn, the rest once at the frame at the last point, which focuses the pane one resolve per
    /// move would have.
    @Test func eightHoverMovesInAFrameResolveFocusAtMostTwice() throws {
        let hover = Hover(coalesced: true)
        defer { hover.close() }
        let p1 = try hover.center("p1"), p2 = try hover.center("p2")
        let points = (0..<Self.dragCount).map { $0.isMultiple(of: 2) ? p1 : p2 }
        hover.move(points[0])
        #expect(hover.root.hoveredPane == "p1", "the leading move resolved the hover in its own turn")
        for point in points.dropFirst() { hover.move(point) }
        #expect(hover.root.hoveredPane == "p1", "moves after the leading one wait for the frame")
        #expect(hover.model.focusedPane == "p1")
        hover.frames.frame()
        #expect(hover.root.hoverFocus.maxDeliveriesPerFrame <= 2,
                "eight moves in a frame resolved the hover \(hover.root.hoverFocus.maxDeliveriesPerFrame) times")
        #expect(hover.root.hoveredPane == "p2")

        let perEvent = Hover(coalesced: false)
        defer { perEvent.close() }
        for point in points { perEvent.move(point) }
        #expect(perEvent.root.hoverFocus.maxDeliveriesPerFrame == 0, "without hover frames each move resolves at once")
        #expect(hover.model.focusedPane == perEvent.model.focusedPane, "the frame's focus is the per-move focus")
        #expect(hover.model.focusedPane == "p2")
    }

    /// With focus follows mouse off, a move posts nothing to the coalescer: there is nothing to resolve.
    @Test func hoverWithTheSettingOffPostsNothing() throws {
        let hover = Hover(coalesced: true)
        defer { hover.close() }
        hover.model.focusFollowsMouseOverride = false
        hover.move(try hover.center("p2"))
        #expect(!hover.root.hoverFocus.hasPending)
        #expect(!hover.frames.coalescer.hasPending)
        #expect(hover.model.focusedPane == "p1")
    }
}
