import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextLayout
import CoreGraphics
import QuartzCore
import CmuxNextWakeups
import Testing

/// A strip pan at O(1) per input event: with `motion.renderServer` on, the strip's
/// hosts and dividers sit in the motion container and their rings and dims in its companion plane, and a
/// pan event sets the translation of the two layers, with no host, divider or ring frame set, no overlay
/// sync and no layout. Pointer input (a press, a move, a new gesture) lands the strip where it shows
/// before any view reads it; the gesture's end lays the views out once at its target and flings the
/// translation on the render server. Content placed from frames (a Chromium page window, the floating
/// panes' shade) or a docked column keeps the pan on the frames.
@MainActor @Suite(.serialized) struct StripPanContainerTests {
    /// Calls of a fling's landing.
    @MainActor final class Counter {
        var value = 0
    }

    /// A pane's content that counts AppKit's tracking-area and cursor-rect rebuilds of it.
    final class TrackedContent: NSView {
        var trackingAreaUpdates = 0
        var cursorRectResets = 0

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreaUpdates += 1
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            cursorRectResets += 1
            addCursorRect(bounds, cursor: .iBeam)
        }
    }

    /// Three 60% columns on a 1000 pt window (`LayoutScrollModifierTests.columnsModel`); the first
    /// holds the rows `top`, `middle`, `bottom`. With `input`, the window is on screen (events name it)
    /// and the root routes through that tap.
    final class Window {
        let provider = LayoutScrollModifierTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(renderServer: Bool, modifier: LayoutScrollModifier = .command, input: InputEventTap? = nil,
             make: ((PaneID) -> NSView)? = nil) {
            _ = NSApplication.shared
            model = LayoutScrollModifierTests.columnsModel(modifier: modifier)
            if let make { provider.make = make }
            var signals = ScrollFocusSignals()
            signals.secondsSinceKeyDown = { 60 }
            signals.windowIsKey = { _ in true }
            signals.mouseButtonsDown = { false }
            root = LayoutRootView(model: model, contentProvider: provider, scrollFocusSignals: signals,
                                  rendersMotionOnServer: { renderServer }, input: input, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window.isReleasedWhenClosed = false
            if input != nil { window.orderFrontRegardless() }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.flushOverlaySync()
        }

        func close() { window.orderOut(nil) }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            let shown = frame.intersection(root.bounds)
            return root.convert(CGPoint(x: shown.midX, y: shown.midY), to: nil)
        }

        @discardableResult
        func scroll(at point: CGPoint, dx: Int32 = 0, phase: CGScrollPhase, command: Bool = true) -> Bool {
            LayoutScrollModifierTests.scroll(root, at: point, dx: dx, phase: phase, command: command)
        }

        /// A gesture's start and `events` moves of `dx` each, the finger still down.
        func pan(at point: CGPoint, events: Int, dx: Int32, command: Bool = true) {
            scroll(at: point, phase: .began, command: command)
            for _ in 0..<events { scroll(at: point, dx: dx, phase: .changed, command: command) }
        }

        /// A pointer event of `type` at `point` (window coordinates) that names this window.
        func pointer(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1))
            try #require(event.window === window, "the event does not name the layout's window")
            return event
        }

        /// The view AppKit sends a press at `point` (window coordinates) to.
        func hit(at point: CGPoint) -> NSView? { root.hitTest(root.superview?.convert(point, from: nil) ?? point) }

        /// The translation `layer`'s model holds.
        static func translation(of layer: CALayer?) -> CGFloat {
            layer.flatMap { StripClipContainerView.translationKey.value(of: $0) } ?? .nan
        }

        func settle() { for _ in 0..<600 where root.advanceFrame(1.0 / 120) {} }
    }

    static let strip: [PaneID] = ["top", "middle", "bottom", "p2", "p3"]

    @Test func offThePanMovesTheHostsAsBefore() throws {
        let w = Window(renderServer: false)
        #expect(w.screen.dividerViews.values.allSatisfy { $0.superview === w.screen }, "the dividers stay in the screen")
        let host = try #require(w.root.context.hosts["p2"])
        let before = host.frame
        let point = try w.center("p2")
        w.pan(at: point, events: 5, dx: -4)
        #expect(w.screen.stripContainer.translation == 0 && w.screen.stripContainer.translationSets == 0)
        #expect(host.frame.minX < before.minX - 1, "the CPU path moves the host's frame")
        w.scroll(at: point, phase: .ended)
        w.settle()
    }

    @Test func aPanThatMovesTheFramesKeepsTheTicksUntilTheFingerLifts() throws {
        let w = Window(renderServer: false)
        let point = try w.center("p2")
        w.pan(at: point, events: 1, dx: -4)
        // Longer than any tail of ticks after the last event: the finger is still down.
        for _ in 0..<30 { #expect(w.root.advanceFrame(1.0 / 120), "a held pan keeps the display link") }
        w.scroll(at: point, phase: .ended)
        w.settle()
        #expect(!w.root.advanceFrame(1.0 / 120), "after the landing no tick is kept")
    }

    @Test func onTheStripsHostsAndDividersSitInTheMotionContainer() {
        let w = Window(renderServer: true)
        // The first column's rows overflow: they sit in their row's container in the strip container.
        for pane in Self.strip { #expect(w.root.context.hosts[pane]?.isDescendant(of: w.screen.stripContainer) == true) }
        #expect(!w.screen.dividerViews.isEmpty)
        #expect(w.screen.dividerViews.values.allSatisfy { $0.isDescendant(of: w.screen.stripContainer) })
        #expect(w.screen.stripContainer.frame == w.screen.bounds)
        for pane in Self.strip {
            #expect(w.root.context.hosts[pane]?.chrome.isDescendant(of: w.screen.stripChrome) == true, "the rings sit in the strip's plane")
        }
        #expect(w.screen.stripChrome.superview === w.root.overlayPlane && w.screen.stripChrome.frame == w.root.overlayPlane.bounds)
        #expect(w.screen.stripContainer.companion === w.screen.stripChrome.layer)
    }

    @Test func fiftyPanEventsSetOneLayerPropertyEachAndNoFrame() throws {
        let w = Window(renderServer: true) { _ in TrackedContent() }
        let screen = w.screen
        let point = try w.center("p2")
        let hosts = Self.strip.compactMap { w.root.context.hosts[$0] }
        let frames = hosts.map(\.frame)
        let chromeFrames = hosts.map(\.chrome.frame)
        let dividers = Array(screen.dividerViews.values)
        let dividerFrames = dividers.map(\.frame)
        let contents = Self.strip.compactMap { w.provider.views[$0] as? TrackedContent }
        try #require(contents.count == Self.strip.count)
        w.window.displayIfNeeded()
        let tracking = contents.map(\.trackingAreaUpdates), dividerAreas = dividers.map(\.trackingAreaIDs)
        let cursors = contents.map(\.cursorRectResets)
        let shownBefore = try #require(w.root.frame(of: "p2"))
        #expect(w.scroll(at: point, phase: .began), "the layout takes the Command gesture")
        let sets = screen.stripContainer.translationSets
        let passes = w.root.visibilityUpdates
        let placed = w.root.overlayHostsPlaced
        for _ in 0..<50 {
            #expect(w.scroll(at: point, dx: -4, phase: .changed))
            #expect(w.root.model.visiblePanes == screen.visiblePanes(), "a skipped visibility pass would have reported nothing")
            #expect(w.root.model.keepAlivePanes == screen.keepAlivePanes().union(screen.visiblePanes()))
        }
        w.root.flushOverlaySync()
        w.window.displayIfNeeded()
        #expect(hosts.map(\.frame) == frames, "no host frame set during the pan")
        #expect(dividers.map(\.frame) == dividerFrames, "no divider frame set during the pan")
        #expect(hosts.map(\.chrome.frame) == chromeFrames, "no ring or dim frame set during the pan")
        #expect(w.root.overlayHostsPlaced == placed, "no overlay sync places a ring during the pan")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt")
        #expect(dividers.map(\.trackingAreaIDs) == dividerAreas, "the dividers keep their one tracking area")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt")
        #expect(screen.stripContainer.translationSets - sets == 50, "one translation per event")
        #expect(Window.translation(of: screen.stripChrome.layer) == screen.stripContainer.translation,
                "the rings' plane takes the same translation")
        #expect(w.root.visibilityUpdates - passes < 50, "the visibility pass runs only when a pane crosses an edge")
        #expect(!screen.panPresentedInFrame && !screen.panPresentationPending, "no event waits for a frame")
        let shownAfter = try #require(w.root.frame(of: "p2"))
        #expect(abs(shownAfter.minX - (shownBefore.minX - 200)) < 0.5, "the strip shows 200 pt further: \(shownBefore) -> \(shownAfter)")
        #expect(abs(screen.placedFrame(of: hosts[3]).minX - shownAfter.minX) < 0.5, "p2 is placed where it shows")
        #expect(w.root.isLayoutInMotion, "the pan is layout motion while the finger is down")
        #expect(!w.root.advanceFrame(1.0 / 120), "a pan on the container keeps no display frames")
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }

    @Test func aPressDuringThePanLandsTheStripBeforeTheViewReadsIt() throws {
        let tap = InputEventTap()
        let w = Window(renderServer: true, input: tap)
        defer { w.close() }
        let start = try w.center("p2")
        w.pan(at: start, events: 50, dx: -4)
        let shown = try #require(w.root.frame(of: "p2"))
        let host = try #require(w.root.context.hosts["p2"])
        // Left of where p2 is laid out, inside where it shows: only the translation puts p2 there.
        let point = w.root.convert(CGPoint(x: shown.minX + 20, y: shown.midY), to: nil)
        #expect(w.root.convert(point, from: nil).x < w.root.convert(host.frame, from: host.superview).minX, "off p2's frame before the press")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 1, "while the strip shows moved, a move lands it")
        let press = try w.pointer(.leftMouseDown, at: point)
        #expect(w.root.handleMonitored(press) != nil, "the press goes on to the view")
        #expect(w.screen.stripContainer.translation == 0 && !w.screen.stripContainer.showsMoved, "the press landed the strip")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 0, "a strip at rest costs pointer moves nothing")
        let hit = try #require(w.hit(at: point))
        #expect(hit === host || hit.isDescendant(of: host), "hit \(hit)")
        #expect(hit.bounds.contains(hit.convert(point, from: nil)), "the hit view reads the press inside itself")
        #expect(abs(host.convert(point, from: nil).x - 20) < 0.5, "p2 reads the press where it showed under the pointer")
        #expect(w.screen.pane(at: w.screen.convert(point, from: nil)) == "p2", "the press focuses p2")
        let after = try #require(w.root.frame(of: "p2"))
        #expect(abs(after.minX - shown.minX) < 0.5, "nothing moved on screen")
        w.scroll(at: start, phase: .ended)
        w.screen.finishPanFling()
        w.settle()
    }

    @Test func aPressAndAMoveDuringTheFlingLandTheStripWhereItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tap = InputEventTap()
        let w = Window(renderServer: true, input: tap)
        defer { w.close() }
        let screen = w.screen
        let start = try w.center("p2")
        w.pan(at: start, events: 10, dx: -12)
        w.scroll(at: start, phase: .ended)
        try #require(screen.stripContainer.fling != nil, "the fling runs on the render server on this host")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 1)
        let move = try w.pointer(.mouseMoved, at: start)
        tap.dispatching { _ = tap.deliverIntercepts(move) }
        #expect(screen.stripContainer.fling == nil && screen.stripContainer.translation == 0, "the move landed the fling")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 0)
        #expect(screen.hasMotion, "the CPU carries the fling on to its snap point")
        // Laid out where it shows: the next press needs nothing landed.
        let host = try #require(w.root.context.hosts["p2"])
        let shown = try #require(w.root.frame(of: "p2"))
        #expect(abs(w.root.convert(host.frame, from: host.superview).minX - shown.minX) < 0.5)
        let point = w.root.convert(CGPoint(x: shown.midX, y: shown.midY), to: nil)
        let press = try w.pointer(.leftMouseDown, at: point)
        _ = w.root.handleMonitored(press)
        let hit = try #require(w.hit(at: point))
        #expect(hit === host || hit.isDescendant(of: host))
        #expect(abs(host.convert(point, from: nil).x - (point.x - w.root.convert(host.frame, from: host.superview).minX)) < 0.5)
        w.settle()
    }

    @Test func aPressDuringTheFlingHitsThePaneWhereItShowsAtThatPoint() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tap = InputEventTap()
        let w = Window(renderServer: true, input: tap)
        defer { w.close() }
        let start = try w.center("p2")
        w.pan(at: start, events: 10, dx: -12)
        w.scroll(at: start, phase: .ended)
        try #require(w.screen.stripContainer.fling != nil, "the fling runs on the render server on this host")
        let shown = try #require(w.root.frame(of: "p2"))
        let host = try #require(w.root.context.hosts["p2"])
        let visible = shown.intersection(w.root.bounds)
        try #require(visible.width > 60, "p2 shows: \(shown)")
        let point = w.root.convert(CGPoint(x: visible.minX + 30, y: visible.midY), to: nil)
        let press = try w.pointer(.leftMouseDown, at: point)
        _ = w.root.handleMonitored(press)
        #expect(w.screen.stripContainer.fling == nil && w.screen.stripContainer.translation == 0)
        let hit = try #require(w.hit(at: point))
        #expect(hit === host || hit.isDescendant(of: host), "hit \(hit)")
        // The fling moved on by the time the press came; what shows under the pointer is what p2 reads.
        let local = host.convert(point, from: nil)
        #expect(host.bounds.contains(local))
        #expect(abs(local.x - (visible.minX + 30 - shown.minX)) < 2, "p2 reads \(local.x)")
        w.settle()
    }

    @Test func theScrollClaimReadsThePaneWhereItShowsOnceTheStripLanded() throws {
        // `top` claims sideways scroll over its left half (a wide table there).
        let w = Window(renderServer: true, modifier: .noModifier) { pane in
            pane == "top" ? PaneHorizontalScrollClaimTests.TableView() : NSView()
        }
        let start = try w.center("p2")
        w.pan(at: start, events: 50, dx: -4, command: false)
        // What a new gesture, a wheel notch or a press does first (`routeScrollEvent`, `handleMonitored`).
        w.root.landStripsWhereTheyShow()
        #expect(w.screen.stripContainer.translation == 0)
        let top = try #require(w.root.frame(of: "top"))
        let right = w.root.convert(CGPoint(x: top.minX + 450, y: top.midY), to: nil)
        let left = w.root.convert(CGPoint(x: top.minX + 250, y: top.midY), to: nil)
        #expect(!w.root.paneContentClaimsHorizontalScroll(at: right))
        #expect(w.root.paneContentClaimsHorizontalScroll(at: left))
    }

    @Test func theGestureEndLaysTheStripOutOnceAtItsTarget() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = Window(renderServer: true)
        let screen = w.screen
        let point = try w.center("p2")
        w.pan(at: point, events: 10, dx: -12)
        let released = screen.scroll.value
        w.scroll(at: point, phase: .ended)
        let camera = screen.scrollState.spring
        let flings = Motion.panes.renderSpring(.scroll).animates(StripClipContainerView.translationKey.path, in: screen.stripContainer)
        if flings {
            #expect(screen.stripContainer.fling != nil, "the fling runs on the render server")
            #expect(camera.value == camera.target && camera.velocity == 0, "the reducer rests on the fling's target")
            #expect(!screen.hasMotion, "the CPU steps nothing")
            #expect(screen.laidOutStripOffset == camera.target, "the views are laid out at the target, once")
            #expect(screen.stripContainer.translation == 0)
            #expect(abs(screen.scroll.value - released) < 50, "the strip shows where it was released, on its way")
            let frames = Self.strip.compactMap { w.root.context.hosts[$0]?.frame }
            for _ in 0..<5 { _ = w.root.advanceFrame(1.0 / 120) }
            #expect(Self.strip.compactMap { w.root.context.hosts[$0]?.frame } == frames, "no frame set during the fling")
            screen.finishPanFling()
        } else {
            w.settle()
        }
        #expect(screen.stripContainer.fling == nil && screen.stripContainer.translation == 0)
        let host = try #require(w.root.context.hosts["p2"])
        #expect(try #require(w.root.frame(of: "p2")).minX == w.root.convert(host.frame, from: host.superview).minX,
                "at rest the strip shows where it is laid out")
        #expect(!w.root.isLayoutInMotion)
    }

    @Test func aNewGestureDuringTheFlingLandsItWhereTheStripShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = Window(renderServer: true)
        let screen = w.screen
        let point = try w.center("p2")
        w.pan(at: point, events: 10, dx: -12)
        w.scroll(at: point, phase: .ended)
        try #require(screen.stripContainer.fling != nil, "the fling runs on the render server on this host")
        // The touch decides the next gesture's owner on the frames: the strip lands where it shows first.
        w.scroll(at: point, phase: .mayBegin)
        #expect(screen.stripContainer.fling == nil && screen.stripContainer.translation == 0, "the touch landed the fling")
        let landed = screen.scrollState.spring.value
        #expect(screen.laidOutStripOffset == landed, "the views are laid out where the strip showed")
        w.scroll(at: point, phase: .began)
        w.scroll(at: point, dx: -4, phase: .changed)
        #expect(screen.panBase == landed, "the new pan moves the views from there")
        // What shows is the reducer's camera: the views' offset less the container's translation.
        #expect(abs(screen.layoutOffset - screen.stripContainer.translation - screen.scrollState.spring.value) < 0.001)
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }

    // MARK: Resampled pan (feature `stripPanResampling`)

    /// The container's translation shows the strip at camera `offset` over the views laid out at the pan's base.
    private static func shows(_ offset: CGFloat, on screen: ScreenContentView) -> Bool {
        guard let base = screen.panBase else { return false }
        let translation = screen.geometry.viewShift(offset: offset) - screen.geometry.viewShift(offset: base)
        return abs(screen.stripContainer.translation - translation) < 0.001
    }

    /// A display-link frame at `time`: the frame time the layout's step reads (`DisplayLinkDriver.frameTime`).
    @discardableResult
    private static func displayFrame(_ w: Window, at time: CFTimeInterval) -> Bool {
        w.root.driver.motionStep(FrameTick(timestamp: time, elapsed: 1.0 / 120, rawElapsed: 1.0 / 120, refreshInterval: 1.0 / 120))
    }

    /// Resampling on: a resampled pan on the container, three events 8 ms apart of 10 pt each.
    private static func resampledPan(_ w: Window) {
        w.root.resamplesStripPan = true
        w.screen.beginUserScroll(trackpad: true)
        for step in 0..<3 { w.screen.userScroll(deltaX: -10, timestamp: 10 + Double(step) * 0.008) }
    }

    /// A pan that begins during a fling (the screen reports the camera on settle) or beside a running pane
    /// spring presents in the frame's spring step: that presentation keeps the frame's resampled offset, not
    /// the real one, so the resampling shows and the strip never steps back when the springs land.
    @Test func theFramesSpringStepKeepsTheResampledPan() throws {
        let w = Window(renderServer: true)
        defer { w.close() }
        let screen = w.screen
        let base = screen.scrollState.spring.value
        Self.resampledPan(w)
        try #require(screen.scrollState.resamplesPan && screen.panBase != nil, "a resampled pan on the container")
        // As after `takeCameraFromServer`: every frame's `step` presents the strip.
        screen.reportScrollOnSettle = true
        Self.displayFrame(w, at: 10.019)
        let shown = try #require(screen.scrollState.presentedPan)
        #expect(abs(shown - (base + 27.5)) < 0.001, "the frame resamples between the two newest events")
        #expect(screen.scrollState.spring.value == base + 30, "the camera keeps the real offset")
        #expect(Self.shows(shown, on: screen),
                "the strip shows the resampled offset after the spring step")
        // A frame with no new event shows the same offset, also through the spring step.
        Self.displayFrame(w, at: 10.027)
        #expect(Self.shows(shown, on: screen))
        screen.endUserScroll(timestamp: 10.03)
        screen.finishPanFling()
        w.settle()
    }

    /// Reduce Motion (or the panes animation switch) turned on mid-pan steps no frames: each event shows at once,
    /// unresampled, and the event that waited for a frame shows in Reduce Motion's settling frame.
    @Test func reduceMotionMidPanShowsEachEventAtOnce() throws {
        let w = Window(renderServer: true)
        defer { w.close() }
        let screen = w.screen
        Self.resampledPan(w)
        Self.displayFrame(w, at: 10.019)
        screen.userScroll(deltaX: -10, timestamp: 10.024)
        w.root.context.reduceMotionOverride = true
        Self.displayFrame(w, at: 10.027)
        let real = screen.scrollState.spring.value
        #expect(Self.shows(real, on: screen),
                "the waiting event shows in the settling frame")
        screen.userScroll(deltaX: -10, timestamp: 10.032)
        #expect(screen.scrollState.spring.value == real + 10)
        #expect(Self.shows(real + 10, on: screen),
                "the event shows at once")
        screen.endUserScroll(timestamp: 10.04)
        screen.finishPanFling()
        w.settle()
    }

    /// Only a trackpad pan resamples: a scrollbar thumb drag follows the pointer, as Chromium resamples
    /// touchpad and touchscreen scroll updates only.
    @Test func onlyATrackpadPanResamples() throws {
        let w = Window(renderServer: true)
        defer { w.close() }
        let screen = w.screen
        w.root.resamplesStripPan = true
        let point = try w.center("p2")
        w.pan(at: point, events: 1, dx: -4)
        #expect(screen.scrollState.resamplesPan, "the trackpad pan resamples")
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
        // The scrollbar's `onDragBegan`.
        screen.beginUserScroll()
        #expect(!screen.scrollState.resamplesPan, "a thumb drag does not")
        screen.endUserScroll(timestamp: 20)
        screen.finishPanFling()
        w.settle()
    }

    @Test func whileAPageWindowShowsTheStripPansItsFrames() throws {
        let w = Window(renderServer: true)
        // The window adopts the overlay plane exactly while a Chromium page shows in a child window
        // (`WindowOverlayLayer`); a page window is placed from its host's frame.
        let panel = NSView(frame: w.root.bounds)
        panel.addSubview(w.root.overlayPlane)
        let host = try #require(w.root.context.hosts["p2"])
        let before = host.frame
        let point = try w.center("p2")
        w.pan(at: point, events: 5, dx: -4)
        #expect(w.screen.stripContainer.translation == 0 && !w.screen.stripContainer.showsMoved, "no translation")
        #expect(host.frame.minX < before.minX - 1, "the host's frame moves, and the page window placed from it follows")
        let shown = try #require(w.root.frame(of: "p2"))
        #expect(abs(shown.minX - w.root.convert(host.frame, from: host.superview).minX) < 0.5)
        w.scroll(at: point, phase: .ended)
        #expect(w.screen.stripContainer.fling == nil, "the fling moves the frames too")
        w.settle()
    }

    @Test func aPageWindowThatShowsDuringTheFlingLandsIt() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = Window(renderServer: true)
        let point = try w.center("p2")
        w.pan(at: point, events: 10, dx: -12)
        w.scroll(at: point, phase: .ended)
        try #require(w.screen.stripContainer.fling != nil, "the fling runs on the render server on this host")
        let panel = NSView(frame: w.root.bounds)
        panel.addSubview(w.root.overlayPlane)
        #expect(w.screen.stripContainer.fling == nil && w.screen.stripContainer.translation == 0, "the page window's arrival landed it")
        let host = try #require(w.root.context.hosts["p2"])
        let shown = try #require(w.root.frame(of: "p2"))
        #expect(abs(shown.minX - w.root.convert(host.frame, from: host.superview).minX) < 0.5,
                "p2's frame is where it shows, so its page window is too")
        w.settle()
    }

    @Test func aScreenWithADockedColumnPansAndFlingsItsFrames() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
            LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
        ])
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
        model.followsDesignMetrics = false
        model.scrollModifierOverride = .command
        let provider = LayoutScrollModifierTests.Panes()
        let root = LayoutRootView(model: model, contentProvider: provider, rendersMotionOnServer: { true }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let screen = try #require(root.screenViews["s"])
        try #require(!screen.geometry.dock.isEmpty && screen.acceptsHorizontalScroll)
        #expect(!screen.pansOnContainer, "the rings' dock covers stay where the dock is")
        let host = try #require(root.context.hosts["p2"])
        let before = host.frame
        let frame = try #require(root.frame(of: "p2"))
        let point = root.convert(CGPoint(x: frame.intersection(root.bounds).midX, y: frame.midY), to: nil)
        LayoutScrollModifierTests.scroll(root, at: point, phase: .began, command: true)
        for _ in 0..<10 { LayoutScrollModifierTests.scroll(root, at: point, dx: -12, phase: .changed, command: true) }
        #expect(screen.stripContainer.translation == 0 && !screen.stripContainer.showsMoved)
        #expect(host.frame.minX < before.minX - 1, "the CPU path moves the frames")
        LayoutScrollModifierTests.scroll(root, at: point, phase: .ended, command: true)
        for _ in 0..<5 {
            #expect(screen.stripContainer.fling == nil, "no ring springs on the render server beside a dock")
            _ = root.advanceFrame(1.0 / 120)
        }
        for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
    }

    @Test func aFlingShowsTheClosedFormAndStopsWhereItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var time: CFTimeInterval = 100
        let container = StripClipContainerView(frame: .zero, now: { time })
        container.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let companion = CALayer()
        container.companion = companion
        let spring = Motion.panes.renderSpring(.scroll)
        try #require(spring.animates(StripClipContainerView.translationKey.path, in: container), "movement is off on this host")
        let landed = Counter()
        var changes = 0
        container.onShowsMovedChange = { changes += 1 }
        #expect(container.startFling(from: -300, velocity: -2000, spring: spring) { landed.value += 1 })
        #expect(container.translation == 0, "the model rests at zero")
        #expect(Window.translation(of: companion) == 0, "the companion's model rests at zero too")
        #expect(container.showsMoved && changes == 1)
        #expect(container.shownTranslation == -300, "it shows the displacement at its start")
        time += 0.05
        let expected = SpringValue.solve(displacement: -300, velocity: -2000, time: 0.05, parameters: spring.parameters)
        #expect(abs(container.shownTranslation - CGFloat(expected.displacement)) < 1e-6)
        let stopped = container.stopFling()
        #expect(abs(stopped.translation - CGFloat(expected.displacement)) < 1e-6)
        #expect(abs(stopped.velocity - CGFloat(expected.velocity)) < 1e-6)
        #expect(container.fling == nil && container.translation == stopped.translation, "the model holds what showed")
        #expect(Window.translation(of: companion) == stopped.translation, "and so does the companion's")
        #expect(landed.value == 0, "a stopped fling never lands")
        container.setTranslation(0)
        #expect(!container.showsMoved && changes == 2)
    }

    @Test func hitTestingReadsTheLaidOutFrames() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let container = StripClipContainerView(frame: .zero)
        container.frame = parent.bounds
        parent.addSubview(container)
        let child = NSView(frame: CGRect(x: 600, y: 0, width: 400, height: 800))
        container.addSubview(child)
        container.setTranslation(-300)
        #expect(container.translationSets == 1)
        // AppKit converts the event's point without the translation: pointer input lands the strip
        // first (`LayoutRootView.landStripsWhereTheyShow`), so hit testing agrees with that point.
        #expect(container.hitTest(NSPoint(x: 800, y: 400)) === child)
        #expect(container.hitTest(NSPoint(x: 400, y: 400)) == nil, "clicks outside every host go to the screen")
    }
}

extension DividerHandleView {
    /// The identities of the handle's own tracking areas (init's hover area and the cursor area at its rect):
    /// a pan or fling, which sets no frame, keeps them.
    var trackingAreaIDs: [ObjectIdentifier] {
        trackingAreas.filter { ($0.owner as? NSView) === self }.map { ObjectIdentifier($0) }
    }
}
