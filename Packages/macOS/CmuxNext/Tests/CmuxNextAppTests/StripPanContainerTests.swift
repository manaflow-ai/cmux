import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import QuartzCore
import Testing

/// A strip pan at O(1) per input event (p03-rendering-026): with `motion.renderServer` on, the strip's
/// hosts and dividers sit in the motion container, and a pan event sets its translation, one layer
/// property, with no host or divider frame set and no layout. Hit testing and the scroll claim see
/// the strip where it shows; the gesture's end lays the views out once at its target and flings the
/// translation on the render server; a new gesture takes the camera where the strip shows.
@MainActor @Suite(.serialized) struct StripPanContainerTests {
    /// Calls of a fling's landing.
    @MainActor final class Counter {
        var value = 0
    }

    /// Three 60% columns on a 1000 pt window (`LayoutScrollModifierTests.columnsModel`); the first
    /// holds the rows `top`, `middle`, `bottom`.
    final class Window {
        let provider = LayoutScrollModifierTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(renderServer: Bool, modifier: LayoutScrollModifier = .command, make: ((PaneID) -> NSView)? = nil) {
            model = LayoutScrollModifierTests.columnsModel(modifier: modifier)
            if let make { provider.make = make }
            var signals = ScrollFocusSignals()
            signals.secondsSinceKeyDown = { 60 }
            signals.windowIsKey = { _ in true }
            signals.mouseButtonsDown = { false }
            root = LayoutRootView(model: model, contentProvider: provider, scrollFocusSignals: signals,
                                  rendersMotionOnServer: { renderServer })
            root.context.reduceMotionOverride = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

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

        func settle() { for _ in 0..<600 where root.advanceFrame(1.0 / 120) {} }
    }

    static let strip: [PaneID] = ["top", "middle", "bottom", "p2", "p3"]

    @Test func offTheStripStaysInTheScreenAsBefore() {
        let w = Window(renderServer: false)
        #expect(w.screen.panContainer.subviews.isEmpty)
        for pane in Self.strip { #expect(w.root.context.hosts[pane]?.superview === w.screen) }
        #expect(w.screen.dividerViews.values.allSatisfy { $0.superview === w.screen })
    }

    @Test func onTheStripsHostsAndDividersSitInTheMotionContainer() {
        let w = Window(renderServer: true)
        for pane in Self.strip { #expect(w.root.context.hosts[pane]?.superview === w.screen.panContainer) }
        #expect(!w.screen.dividerViews.isEmpty)
        #expect(w.screen.dividerViews.values.allSatisfy { $0.superview === w.screen.panContainer })
        #expect(w.screen.panContainer.frame == w.screen.bounds)
    }

    @Test func fiftyPanEventsSetOneLayerPropertyEachAndNoFrame() throws {
        let w = Window(renderServer: true)
        let screen = w.screen
        let point = try w.center("p2")
        let hosts = Self.strip.compactMap { w.root.context.hosts[$0] }
        let frames = hosts.map(\.frame)
        let dividers = Array(screen.dividerViews.values)
        let dividerFrames = dividers.map(\.frame)
        let shownBefore = try #require(w.root.frame(of: "p2"))
        #expect(w.scroll(at: point, phase: .began), "the layout takes the Command gesture")
        let sets = screen.panContainer.translationSets
        let passes = w.root.visibilityUpdates
        for _ in 0..<50 {
            #expect(w.scroll(at: point, dx: -4, phase: .changed))
            #expect(w.root.model.visiblePanes == screen.visiblePanes(), "a skipped visibility pass would have reported nothing")
            #expect(w.root.model.keepAlivePanes == screen.keepAlivePanes().union(screen.visiblePanes()))
        }
        #expect(hosts.map(\.frame) == frames, "no host frame set during the pan")
        #expect(dividers.map(\.frame) == dividerFrames, "no divider frame set during the pan")
        #expect(screen.panContainer.translationSets - sets == 50, "one layer property per event")
        #expect(w.root.visibilityUpdates - passes < 50, "the visibility pass runs only when a pane crosses an edge")
        #expect(screen.panTicksLeft == 0 && !screen.panPresentedInFrame, "a pan on the container keeps no display frames")
        let shownAfter = try #require(w.root.frame(of: "p2"))
        #expect(abs(shownAfter.minX - (shownBefore.minX - 200)) < 0.5, "the strip shows 200 pt further: \(shownBefore) -> \(shownAfter)")
        #expect(abs(screen.placedFrame(of: hosts[3]).minX - shownAfter.minX) < 0.5, "p2 is placed where it shows")
        #expect(w.root.isLayoutInMotion, "the pan is layout motion while the finger is down")
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }

    @Test func aClickDuringThePanHitsThePaneUnderThePointer() throws {
        let w = Window(renderServer: true)
        w.pan(at: try w.center("p2"), events: 50, dx: -4)
        let shown = try #require(w.root.frame(of: "p2"))
        let host = try #require(w.root.context.hosts["p2"])
        // Left of where p2 is laid out, inside where it shows: only the translation puts p2 there.
        let local = CGPoint(x: shown.minX + 20, y: shown.midY)
        #expect(local.x < host.frame.minX, "the point is off p2's laid-out frame")
        let hit = w.root.hitTest(w.root.convert(local, to: w.root.superview))
        #expect(hit.map { $0 === host || $0.isDescendant(of: host) } == true, "hit \(String(describing: hit))")
        #expect(w.screen.pane(at: w.screen.convert(local, from: w.root)) == "p2", "the click focuses p2")
    }

    @Test func theScrollClaimReadsThePaneWhereItShows() throws {
        // `top` claims sideways scroll over its left half (a wide table there).
        let w = Window(renderServer: true, modifier: .noModifier) { pane in
            pane == "top" ? PaneHorizontalScrollClaimTests.TableView() : NSView()
        }
        w.pan(at: try w.center("p2"), events: 50, dx: -4, command: false)
        let top = try #require(w.root.frame(of: "top"))
        // `top` shows 200 pt left of where it is laid out: shown at 250 pt it is laid out at 450, its right half.
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
        let flings = Motion.panes.renderSpring(.scroll).animates(StripPanContainerView.translationKeyPath, in: screen.panContainer)
        if flings {
            #expect(screen.panContainer.fling != nil, "the fling runs on the render server")
            #expect(camera.value == camera.target && camera.velocity == 0, "the reducer rests on the fling's target")
            #expect(!screen.hasMotion, "the CPU steps nothing")
            #expect(screen.laidOutStripOffset == camera.target, "the views are laid out at the target, once")
            #expect(screen.panContainer.translation == 0)
            #expect(abs(screen.scroll.value - released) < 50, "the strip shows where it was released, on its way")
            let frames = Self.strip.compactMap { w.root.context.hosts[$0]?.frame }
            for _ in 0..<5 { _ = w.root.advanceFrame(1.0 / 120) }
            #expect(Self.strip.compactMap { w.root.context.hosts[$0]?.frame } == frames, "no frame set during the fling")
            screen.finishPanFling()
        } else {
            w.settle()
        }
        #expect(screen.panContainer.fling == nil && screen.panContainer.translation == 0)
        let host = try #require(w.root.context.hosts["p2"])
        #expect(try #require(w.root.frame(of: "p2")).minX == w.root.convert(host.frame, from: host.superview).minX,
                "at rest the strip shows where it is laid out")
        #expect(!w.root.isLayoutInMotion)
    }

    @Test func aNewGestureDuringTheFlingTakesTheCameraWhereTheStripShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = Window(renderServer: true)
        let screen = w.screen
        let point = try w.center("p2")
        w.pan(at: point, events: 10, dx: -12)
        w.scroll(at: point, phase: .ended)
        try #require(screen.panContainer.fling != nil, "the fling runs on the render server on this host")
        let target = screen.scrollState.spring.target
        w.pan(at: point, events: 1, dx: -4)
        #expect(screen.panContainer.fling == nil, "the gesture took the camera")
        #expect(screen.panBase == target, "the views stay laid out at the fling's target")
        // What shows is the reducer's camera: the views' offset less the container's translation.
        #expect(abs(screen.layoutOffset - screen.panContainer.translation - screen.scrollState.spring.value) < 0.001)
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }

    @Test func aFlingShowsTheClosedFormAndStopsWhereItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var time: CFTimeInterval = 100
        let container = StripPanContainerView(now: { time })
        container.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let spring = Motion.panes.renderSpring(.scroll)
        try #require(spring.animates(StripPanContainerView.translationKeyPath, in: container), "movement is off on this host")
        let landed = Counter()
        #expect(container.startFling(from: -300, velocity: -2000, spring: spring, with: []) { landed.value += 1 })
        #expect(container.translation == 0, "the model rests at zero")
        #expect(container.shownTranslation == -300, "it shows the displacement at its start")
        time += 0.05
        let expected = SpringValue.solve(displacement: -300, velocity: -2000, time: 0.05, parameters: spring.parameters)
        #expect(abs(container.shownTranslation - CGFloat(expected.displacement)) < 1e-6)
        let stopped = container.stopFling()
        #expect(abs(stopped.translation - CGFloat(expected.displacement)) < 1e-6)
        #expect(abs(stopped.velocity - CGFloat(expected.velocity)) < 1e-6)
        #expect(container.fling == nil && container.translation == stopped.translation, "the model holds what showed")
        #expect(landed.value == 0, "a stopped fling never lands")
    }

    @Test func hitTestingMapsThePointThroughTheTranslation() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let container = StripPanContainerView()
        container.frame = parent.bounds
        parent.addSubview(container)
        let child = NSView(frame: CGRect(x: 600, y: 0, width: 400, height: 800))
        container.addSubview(child)
        container.setTranslation(-300)
        #expect(container.translationSets == 1)
        #expect(container.hitTest(NSPoint(x: 400, y: 400)) === child, "it shows at 300...700")
        #expect(container.hitTest(NSPoint(x: 800, y: 400)) == nil, "laid out there, it shows nothing there")
    }
}
