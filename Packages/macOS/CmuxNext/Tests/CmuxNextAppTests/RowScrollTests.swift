import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextLayout
import CoreGraphics
import QuartzCore
import Testing

/// Rows pan by translation: with `motion.renderServer` on, the hosts and dividers of a
/// strip column whose rows overflow sit in the row's motion container and their rings in its chrome
/// plane, and a row pan event sets the translation of those two layers: no host, divider or ring frame
/// set, no tracking area or cursor rect rebuilt. A press during the pan lands the rows where they show
/// before the view reads it; the gesture's end lays them out once where they show.
@MainActor @Suite(.serialized) struct RowScrollTests {
    typealias Window = StripPanContainerTests.Window
    static let rows: [PaneID] = ["top", "middle", "bottom"]

    /// One scroll event of a Command row pan at `point` (window coordinates).
    @discardableResult
    static func scroll(_ w: Window, at point: CGPoint, dy: Int32 = 0, phase: CGScrollPhase) -> Bool {
        LayoutScrollModifierTests.scroll(w.root, at: point, dy: dy, phase: phase, command: true)
    }

    /// A row pan's start and `events` moves of `dy` each, the finger still down.
    static func pan(_ w: Window, at point: CGPoint, events: Int, dy: Int32) {
        scroll(w, at: point, phase: .began)
        for _ in 0..<events { scroll(w, at: point, dy: dy, phase: .changed) }
    }

    /// The vertical translation `view`'s layer `sublayerTransform` holds, in the view's own axes.
    static func translationY(of view: NSView) -> CGFloat {
        (view.layer?.sublayerTransform.m42 ?? .nan) * RenderLayerAxes(view).y
    }

    /// `pane`'s host frame in the root's coordinates, where it is laid out.
    static func laidOut(_ w: Window, _ pane: PaneID) throws -> CGRect {
        let host = try #require(w.root.context.hosts[pane])
        return w.root.convert(host.frame, from: host.superview)
    }

    @Test func theLayoutOffsetIsTheCameraUntilAPanHoldsABase() {
        var scroll = RowScroll()
        scroll.state.spring.value = 120
        #expect(scroll.layoutOffset == 120)
        scroll.panBase = 40
        scroll.state.spring.value = 200
        #expect(scroll.layoutOffset == 40, "the views stay where the pan started")
        scroll.panBase = nil
        #expect(scroll.layoutOffset == 200)
    }

    @Test func theRowsHostsAndDividersSitInTheRowsContainer() throws {
        let w = Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.row("c1")), "the first column's rows overflow")
        #expect(container.superview === screen.stripContainer)
        for pane in Self.rows { #expect(w.root.context.hosts[pane]?.superview === container) }
        #expect(w.root.context.hosts["p2"]?.superview === screen.stripContainer, "a column without rows stays in the strip container")
        let rowDividers = screen.dividerViews.filter { screen.rowColumn(of: $0.key) == "c1" }
        #expect(!rowDividers.isEmpty && rowDividers.values.allSatisfy { $0.superview === container })
        for pane in Self.rows { #expect(w.root.context.hosts[pane]?.chrome.superview === container.chromePlane, "the rings sit in the row's plane") }
        #expect(container.chromePlane.superview === screen.stripChrome)
        #expect(!container.clipsSubviews, "rows clip nothing of their own")
    }

    @Test func withoutTheRenderServerTheRowsMoveTheirFrames() throws {
        let w = Window(renderServer: false)
        #expect(w.screen.scrollerContainers.isEmpty)
        let host = try #require(w.root.context.hosts["top"])
        let before = host.frame
        let point = try w.center("top")
        Self.pan(w, at: point, events: 5, dy: -4)
        #expect(host.frame.minY < before.minY - 1, "the CPU path moves the host's frame")
        Self.scroll(w, at: point, phase: .ended)
        w.settle()
    }

    @Test func twentyRowPanEventsSetOneLayerPropertyEachAndNoFrame() throws {
        let w = Window(renderServer: true) { _ in StripPanContainerTests.TrackedContent() }
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.row("c1")))
        let hosts = Self.rows.compactMap { w.root.context.hosts[$0] }
        let frames = hosts.map(\.frame), chromeFrames = hosts.map(\.chrome.frame)
        let dividers = screen.dividerViews.values.filter { $0.superview === container }
        let dividerFrames = dividers.map(\.frame)
        let contents = Self.rows.compactMap { w.provider.views[$0] as? StripPanContainerTests.TrackedContent }
        try #require(contents.count == Self.rows.count)
        w.window.displayIfNeeded()
        let tracking = contents.map(\.trackingAreaUpdates), dividerAreas = dividers.map(\.trackingAreaIDs)
        let cursors = contents.map(\.cursorRectResets)
        let point = try w.center("top")
        let shownBefore = try #require(w.root.frame(of: "top"))
        #expect(Self.scroll(w, at: point, phase: .began), "the layout takes the Command gesture")
        let sets = container.translationSets
        let placed = w.root.overlayHostsPlaced
        for _ in 0..<20 { #expect(Self.scroll(w, at: point, dy: -4, phase: .changed)) }
        w.root.flushOverlaySync()
        w.window.displayIfNeeded()
        #expect(hosts.map(\.frame) == frames, "no host frame set during the pan")
        #expect(dividers.map(\.frame) == dividerFrames, "no divider frame set during the pan")
        #expect(hosts.map(\.chrome.frame) == chromeFrames, "no ring or dim frame set during the pan")
        #expect(w.root.overlayHostsPlaced == placed, "no overlay sync places a ring during the pan")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt")
        #expect(dividers.map(\.trackingAreaIDs) == dividerAreas, "the dividers keep their one tracking area")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt")
        #expect(container.translationSets - sets == 20, "one translation per event")
        #expect(screen.stripContainer.translation == 0, "the strip stays")
        #expect(Self.translationY(of: container) == container.translation.dy, "the container's layer holds the translation")
        #expect(Self.translationY(of: container.chromePlane) == container.translation.dy, "the rings' plane takes the same translation")
        #expect(container.translation.dy < -79, "the rows show moved up: \(container.translation)")
        let shownAfter = try #require(w.root.frame(of: "top"))
        #expect(abs(shownAfter.minY - (shownBefore.minY - 80)) < 0.5, "the rows show 80 pt further: \(shownBefore) -> \(shownAfter)")
        let placedTop = w.root.convert(screen.placedFrame(of: hosts[0]), from: screen)
        #expect(abs(placedTop.minY - shownAfter.minY) < 0.5, "top is placed where it shows")
        #expect(w.root.isLayoutInMotion, "the pan is layout motion while the finger is down")
        Self.scroll(w, at: point, phase: .ended)
        w.settle()
    }

    @Test func aPressDuringTheRowPanHitsThePaneUnderThePointer() throws {
        let tap = InputEventTap()
        let w = Window(renderServer: true, input: tap)
        defer { w.close() }
        let container = try #require(w.screen.scrollerContainer(.row("c1")))
        let start = try w.center("top")
        Self.pan(w, at: start, events: 20, dy: -4)
        #expect(container.showsMoved)
        let shown = try #require(w.root.frame(of: "middle"))
        let host = try #require(w.root.context.hosts["middle"])
        // Above where `middle` is laid out, inside where it shows: only the translation puts it there.
        let point = w.root.convert(CGPoint(x: shown.midX, y: shown.minY + 20), to: nil)
        let laidOutMiddle = try Self.laidOut(w, "middle")
        #expect(w.root.convert(point, from: nil).y < laidOutMiddle.minY, "off middle's frame before the press")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 1, "while the rows show moved, a move lands them")
        let press = try w.pointer(.leftMouseDown, at: point)
        #expect(w.root.handleMonitored(press) != nil, "the press goes on to the view")
        #expect(container.translation == .zero && !container.showsMoved, "the press landed the rows")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 0, "rows at rest cost pointer moves nothing")
        let hit = try #require(w.hit(at: point))
        #expect(hit === host || hit.isDescendant(of: host), "hit \(hit)")
        #expect(abs(host.convert(point, from: nil).y - 20) < 0.5, "middle reads the press where it showed under the pointer")
        let after = try #require(w.root.frame(of: "middle"))
        #expect(abs(after.minY - shown.minY) < 0.5, "nothing moved on screen")
        Self.scroll(w, at: start, phase: .ended)
        w.settle()
    }

    @Test func theGestureEndLaysTheRowsOutOnceAtTheirTarget() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.row("c1")))
        let point = try w.center("top")
        Self.pan(w, at: point, events: 10, dy: -6)
        #expect(screen.rowScrolls["c1"]?.panBase != nil, "the pan holds the rows where they were laid out")
        let released = try #require(w.root.frame(of: "top"))
        Self.scroll(w, at: point, phase: .ended)
        let scroll = try #require(screen.rowScrolls["c1"])
        #expect(scroll.panBase == nil)
        #expect(scroll.laidOutOffset == scroll.state.spring.value, "laid out at the offset the reducer holds")
        #expect(container.translation == .zero && Self.translationY(of: container.chromePlane) == 0, "the models rest at zero")
        if container.fling != nil {
            #expect(scroll.state.spring.value == scroll.state.spring.target && scroll.state.spring.velocity == 0,
                    "the reducer rests on the fling's target")
            #expect(!screen.hasMotion, "the CPU steps nothing")
            let shown = try Self.laidOut(w, "top").minY + container.shownPanTranslation.dy
            #expect(abs(shown - released.minY) < 50, "the rows show where they were released, on their way")
            screen.finishPanFling()
        } else {
            w.settle()
        }
        #expect(container.fling == nil && !container.showsMoved)
        let rest = try #require(w.root.frame(of: "top")), laidOutAtRest = try Self.laidOut(w, "top")
        #expect(abs(laidOutAtRest.minY - rest.minY) < 0.5, "at rest the rows show where they are laid out")
        #expect(!w.root.isLayoutInMotion)
    }

    /// The fling after a row pan springs the container's translation on the render server: the rows are
    /// laid out once at its target, and its frames set no host, divider or ring frame and rebuild no
    /// tracking area or cursor rect. A pointer move lands it where it shows; the CPU carries it on.
    @Test func aRowFlingSetsNoFrameAndAMoveLandsItWhereItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tap = InputEventTap()
        let w = Window(renderServer: true, input: tap) { _ in StripPanContainerTests.TrackedContent() }
        defer { w.close() }
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.row("c1")))
        let point = try w.center("top")
        Self.pan(w, at: point, events: 10, dy: -12)
        Self.scroll(w, at: point, phase: .ended)
        try #require(container.fling != nil, "the fling runs on the render server on this host")
        let hosts = Self.rows.compactMap { w.root.context.hosts[$0] }
        let dividers = screen.dividerViews.values.filter { $0.superview === container }
        let contents = Self.rows.compactMap { w.provider.views[$0] as? StripPanContainerTests.TrackedContent }
        let frames = hosts.map(\.frame), chromeFrames = hosts.map(\.chrome.frame), dividerFrames = dividers.map(\.frame)
        w.window.displayIfNeeded()
        let tracking = contents.map(\.trackingAreaUpdates), dividerAreas = dividers.map(\.trackingAreaIDs)
        let cursors = contents.map(\.cursorRectResets)
        for _ in 0..<20 { _ = w.root.advanceFrame(1.0 / 120) }
        w.root.flushOverlaySync()
        w.window.displayIfNeeded()
        #expect(hosts.map(\.frame) == frames, "no host frame set during the fling")
        #expect(hosts.map(\.chrome.frame) == chromeFrames, "no ring or dim frame set during the fling")
        #expect(dividers.map(\.frame) == dividerFrames, "no divider frame set during the fling")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt during the fling")
        #expect(dividers.map(\.trackingAreaIDs) == dividerAreas, "the dividers keep their one tracking area")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt during the fling")
        #expect(w.root.isLayoutInMotion, "the fling is layout motion until it lands")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 1, "while the rows fling, a move lands them")
        let move = try w.pointer(.mouseMoved, at: point)
        tap.dispatching { _ = tap.deliverIntercepts(move) }
        #expect(container.fling == nil && container.translation == .zero, "the move landed the fling")
        #expect(screen.hasMotion, "the CPU carries the fling on to its snap point")
        let shown = try #require(w.root.frame(of: "top")), laidOut = try Self.laidOut(w, "top")
        #expect(abs(laidOut.minY - shown.minY) < 0.5, "laid out where it shows")
        w.settle()
        #expect(!w.root.isLayoutInMotion)
    }

    @Test func aStripPanMovesTheRowsContainerWithTheStrip() throws {
        let w = Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.row("c1")))
        let shownBefore = try #require(w.root.frame(of: "top"))
        let point = try w.center("p2")
        w.pan(at: point, events: 10, dx: -4)
        #expect(container.translation == .zero, "the row container rides the strip container's translation")
        let host = try #require(w.root.context.hosts["top"])
        let placed = w.root.convert(screen.placedFrame(of: host), from: screen)
        let shown = try #require(w.root.frame(of: "top"))
        #expect(abs(shown.minX - (shownBefore.minX - 40)) < 0.5)
        #expect(abs(placed.minX - shown.minX) < 0.5, "top is placed where it shows")
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }
}
