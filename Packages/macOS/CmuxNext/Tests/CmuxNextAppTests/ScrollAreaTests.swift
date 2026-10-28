import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextLayout
import CmuxNextWakeups
import CoreGraphics
import QuartzCore
import Testing

/// Scroll areas pan by translation: with `motion.renderServer` on, an area's hosts and
/// dividers sit in its motion container, which clips them to the area's window (no host carries a mask
/// for it), and an area pan event sets the translation of the container's layer and of its rings'
/// plane: no host frame set, no clip recomputed, no tracking area rebuilt. A press during the pan lands
/// the area where it shows; the gesture's end lays it out once where it shows.
@MainActor @Suite(.serialized) struct ScrollAreaTests {
    /// Two half columns on a 1200 pt window (`LayoutScrollModifierTests.AreaWindow`): the first holds the
    /// chain p1 | p2 | p3, too wide for its column, so it is a scroll area; the second holds `q`. With
    /// `rows`, the chain is the first column's top row, above a row holding `below`.
    final class Window {
        let provider = LayoutScrollModifierTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        /// The layout the window opened with.
        let layout: ScreenLayout

        static let chain: SplitNode = .split("s1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                             b: .split("s2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

        /// The two columns; with `rowHeight` (permille), the first is the chain's row above `below`'s.
        static func layout(rowHeight: Int?) -> ScreenLayout {
            let first = rowHeight.map { height in
                LayoutColumn(id: "c1", width: 0.5, root: .split("rows", axis: .vertical, ratio: 0.5, a: chain, b: .leaf("below")),
                             rows: [LayoutRow(id: "r1", height: height, root: chain), LayoutRow(id: "r2", height: height, root: .leaf("below"))])
            } ?? LayoutColumn(id: "c1", width: 0.5, root: chain)
            return .columns([first, LayoutColumn(id: "c2", width: 0.5, root: .leaf("q"))])
        }

        init(renderServer: Bool, rows: Bool = false, input: InputEventTap? = nil, make: ((PaneID) -> NSView)? = nil) throws {
            _ = NSApplication.shared
            layout = Self.layout(rowHeight: rows ? 500 : nil)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "q")
            if rows { model.rowsEnabledOverride = true }
            model.followsDesignMetrics = false
            model.baseStyle.minimumPaneContentSize = CGSize(width: 300, height: 64)
            model.baseStyle.scrollAreasEnabled = true
            model.scrollModifierOverride = .command
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
            try #require(!screen.areaScrolls.isEmpty, "the first column is a scroll area")
        }

        func close() { window.orderOut(nil) }

        /// Shows `layout` and lets it settle.
        func show(_ layout: ScreenLayout, zoomed: Bool = false) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: zoomed)])
            root.syncWithModel()
            settle()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        /// The area's id: its root split.
        var area: SplitID { "s1" }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane)).intersection(root.bounds)
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        /// One scroll event of a Command area pan at `point` (window coordinates).
        @discardableResult
        func scroll(at point: CGPoint, dx: Int32 = 0, phase: CGScrollPhase) -> Bool {
            LayoutScrollModifierTests.scroll(root, at: point, dx: dx, phase: phase, command: true)
        }

        /// An area pan's start and `events` moves of `dx` each, the finger still down.
        func pan(at point: CGPoint, events: Int, dx: Int32) {
            scroll(at: point, phase: .began)
            for _ in 0..<events { scroll(at: point, dx: dx, phase: .changed) }
        }

        func pointer(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1))
            try #require(event.window === window, "the event does not name the layout's window")
            return event
        }

        func hit(at point: CGPoint) -> NSView? { root.hitTest(root.superview?.convert(point, from: nil) ?? point) }

        /// `pane`'s host frame in the root's coordinates, where it is laid out.
        func laidOut(_ pane: PaneID) throws -> CGRect {
            let host = try #require(root.context.hosts[pane])
            return root.convert(host.frame, from: host.superview)
        }

        func settle() { for _ in 0..<600 where root.advanceFrame(1.0 / 120) {} }
    }

    static let panes: [PaneID] = ["p1", "p2", "p3"]

    @Test func theLayoutOffsetIsTheCameraUntilAPanHoldsABase() {
        var scroll = ScrollAreaScroll()
        scroll.state.spring.value = 90
        #expect(scroll.layoutOffset == 90)
        scroll.panBase = 30
        scroll.state.spring.value = 150
        #expect(scroll.layoutOffset == 30, "the views stay where the pan started")
    }

    @Test func theAreasHostsSitInItsContainerWhichClipsThemToTheWindow() throws {
        let w = try Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        #expect(container.superview === screen.stripContainer)
        for pane in Self.panes {
            let host = try #require(w.root.context.hosts[pane])
            #expect(host.superview === container)
            #expect(host.layer?.mask == nil, "no mask per host: the container clips")
        }
        #expect(w.root.context.hosts["q"]?.superview === screen.stripContainer)
        #expect(container.clipsSubviews)
        let window = try #require(screen.displayedAreaWindow(w.area))
        #expect(container.frame == window && container.bounds.origin == window.origin, "the container is the area's window")
        #expect(screen.pansOnContainer, "an area with its own clip lets the strip pan on its container")
    }

    @Test func withoutTheRenderServerEachHostIsMaskedToTheWindow() throws {
        let w = try Window(renderServer: false)
        #expect(w.screen.scrollerContainers.isEmpty)
        let p3 = try #require(w.root.context.hosts["p3"])
        #expect(p3.layer?.mask != nil, "p3 is past the window: its own mask clips it")
    }

    @Test func twentyAreaPanEventsSetOneLayerPropertyEachAndNoFrame() throws {
        let w = try Window(renderServer: true) { _ in StripPanContainerTests.TrackedContent() }
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        let hosts = Self.panes.compactMap { w.root.context.hosts[$0] }
        let frames = hosts.map(\.frame), chromeFrames = hosts.map(\.chrome.frame), masks = hosts.map { $0.layer?.mask }
        let containerFrame = container.frame
        let contents = Self.panes.compactMap { w.provider.views[$0] as? StripPanContainerTests.TrackedContent }
        try #require(contents.count == Self.panes.count)
        let s2 = try #require(screen.dividerViews[.split("s2")], "the divider between p2 and p3")
        try #require(s2.superview === container, "the area's dividers sit in its container")
        w.window.displayIfNeeded()
        let tracking = contents.map(\.trackingAreaUpdates), cursors = contents.map(\.cursorRectResets)
        let point = try w.center("p1")
        let shownBefore = try #require(w.root.frame(of: "p2"))
        w.scroll(at: point, phase: .began)
        #expect(w.scroll(at: point, dx: -4, phase: .changed), "the area takes the Command gesture")
        let sets = container.translationSets
        let placed = w.root.overlayHostsPlaced
        for _ in 0..<19 { #expect(w.scroll(at: point, dx: -4, phase: .changed)) }
        w.root.flushOverlaySync()
        w.window.displayIfNeeded()
        #expect(hosts.map(\.frame) == frames, "no host frame set during the pan")
        #expect(hosts.map(\.chrome.frame) == chromeFrames, "no ring or dim frame set during the pan")
        let masksAfter: [CALayer?] = hosts.map { $0.layer?.mask }
        let masksUnchanged: Bool = masksAfter.count == masks.count
            && zip(masksAfter, masks).allSatisfy { (after: CALayer?, before: CALayer?) -> Bool in after === before }
        #expect(masksUnchanged, "no mask set during the pan")
        #expect(container.frame == containerFrame, "the clip stays where it is")
        #expect(w.root.overlayHostsPlaced == placed, "no overlay sync places a ring during the pan")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt")
        #expect(container.translationSets - sets == 19, "one translation per event")
        #expect(container.layer?.sublayerTransform.m41 == container.translation.dx, "the container's layer holds the translation")
        #expect(container.chromePlane.layer?.sublayerTransform.m41 == container.translation.dx, "the rings' plane takes the same translation")
        let shownAfter = try #require(w.root.frame(of: "p2"))
        #expect(abs(shownAfter.minX - (shownBefore.minX - 80)) < 0.5, "the area shows 80 pt further: \(shownBefore) -> \(shownAfter)")
        let placedP2 = w.root.convert(screen.placedFrame(of: hosts[1]), from: screen)
        #expect(abs(placedP2.minX - shownAfter.minX) < 0.5, "p2 is placed where it shows")
        // The split line between p2 and p3 shows wherever the pan brings it: the container clips it, not a hide rule.
        let shownS2 = screen.placedFrame(of: s2)
        #expect(container.frame.contains(CGPoint(x: shownS2.midX, y: shownS2.midY)), "the pan brought s2 into the area's window: \(shownS2)")
        #expect(!s2.isHidden, "s2 is hidden inside the area's window")
        w.scroll(at: point, phase: .ended)
        screen.finishPanFling()
        w.settle()
    }

    @Test func aPressDuringTheAreaPanHitsThePaneUnderThePointer() throws {
        let tap = InputEventTap()
        let w = try Window(renderServer: true, input: tap)
        defer { w.close() }
        let container = try #require(w.screen.scrollerContainer(.area(w.area)))
        let start = try w.center("p1")
        w.pan(at: start, events: 20, dx: -4)
        #expect(container.showsMoved)
        let shown = try #require(w.root.frame(of: "p2"))
        let host = try #require(w.root.context.hosts["p2"])
        // Left of where p2 is laid out, inside where it shows: only the translation puts it there.
        let point = w.root.convert(CGPoint(x: shown.minX + 20, y: shown.midY), to: nil)
        let laidOut = try w.laidOut("p2")
        #expect(w.root.convert(point, from: nil).x < laidOut.minX, "off p2's frame before the press")
        let press = try w.pointer(.leftMouseDown, at: point)
        #expect(w.root.handleMonitored(press) != nil, "the press goes on to the view")
        #expect(container.translation == .zero && !container.showsMoved, "the press landed the area")
        let hit = try #require(w.hit(at: point))
        #expect(hit === host || hit.isDescendant(of: host), "hit \(hit)")
        #expect(abs(host.convert(point, from: nil).x - 20) < 0.5, "p2 reads the press where it showed under the pointer")
        w.scroll(at: start, phase: .ended)
        w.settle()
    }

    @Test func theGestureEndLaysTheAreaOutOnceAtItsTarget() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let w = try Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        let point = try w.center("p1")
        w.pan(at: point, events: 10, dx: -6)
        #expect(screen.areaScrolls[w.area]?.panBase != nil, "the pan holds the area where it was laid out")
        let released = try #require(w.root.frame(of: "p2"))
        w.scroll(at: point, phase: .ended)
        let scroll = try #require(screen.areaScrolls[w.area])
        #expect(scroll.panBase == nil)
        #expect(scroll.laidOutOffset == scroll.state.spring.value, "laid out at the offset the reducer holds")
        #expect(container.translation == .zero, "the model rests at zero")
        if container.fling != nil {
            #expect(scroll.state.spring.value == scroll.state.spring.target && scroll.state.spring.velocity == 0,
                    "the reducer rests on the fling's target")
            #expect(!screen.hasMotion, "the CPU steps nothing")
            let shown = try w.laidOut("p2").minX + container.shownPanTranslation.dx
            #expect(abs(shown - released.minX) < 50, "the area shows where it was released, on its way")
            screen.finishPanFling()
        } else {
            w.settle()
        }
        #expect(container.fling == nil && !container.showsMoved)
        let rest = try #require(w.root.frame(of: "p2"))
        let laidOutAtRest = try w.laidOut("p2")
        #expect(abs(laidOutAtRest.minX - rest.minX) < 0.5, "at rest the area shows where it is laid out")
        #expect(!w.root.isLayoutInMotion)
    }

    /// The fling after an area pan springs the container's translation on the render server: the views are
    /// laid out once at its target, and its frames set no host, divider or ring frame and rebuild no
    /// tracking area or cursor rect. A pointer move lands it where it shows; the CPU carries it on.
    @Test func anAreaFlingSetsNoFrameAndAMoveLandsItWhereItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let tap = InputEventTap()
        let w = try Window(renderServer: true, input: tap) { _ in StripPanContainerTests.TrackedContent() }
        defer { w.close() }
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        let start = try w.center("p1")
        w.pan(at: start, events: 10, dx: -12)
        w.scroll(at: start, phase: .ended)
        try #require(container.fling != nil, "the fling runs on the render server on this host")
        let hosts = Self.panes.compactMap { w.root.context.hosts[$0] }
        let dividers = screen.dividerViews.values.filter { $0.superview === container }
        let contents = Self.panes.compactMap { w.provider.views[$0] as? StripPanContainerTests.TrackedContent }
        let frames = hosts.map(\.frame), chromeFrames = hosts.map(\.chrome.frame), dividerFrames = dividers.map(\.frame)
        w.window.displayIfNeeded()
        let tracking = contents.map(\.trackingAreaUpdates), cursors = contents.map(\.cursorRectResets)
        for _ in 0..<20 { _ = w.root.advanceFrame(1.0 / 120) }
        w.root.flushOverlaySync()
        w.window.displayIfNeeded()
        #expect(hosts.map(\.frame) == frames, "no host frame set during the fling")
        #expect(hosts.map(\.chrome.frame) == chromeFrames, "no ring or dim frame set during the fling")
        #expect(dividers.map(\.frame) == dividerFrames, "no divider frame set during the fling")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt during the fling")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt during the fling")
        #expect(w.root.isLayoutInMotion, "the fling is layout motion until it lands")
        #expect(tap.subscriberCount(.pointerMove, stage: .intercept) == 1, "while the area flings, a move lands it")
        let move = try w.pointer(.mouseMoved, at: start)
        tap.dispatching { _ = tap.deliverIntercepts(move) }
        #expect(container.fling == nil && container.translation == .zero, "the move landed the fling")
        #expect(screen.hasMotion, "the CPU carries the fling on to its snap point")
        let shown = try #require(w.root.frame(of: "p2"))
        let laidOut = try w.laidOut("p2")
        #expect(abs(laidOut.minX - shown.minX) < 0.5, "laid out where it shows")
        w.settle()
        #expect(!w.root.isLayoutInMotion)
    }

    /// A zoom of a pane in a scroll area keeps its host in the area's container (no host changes parent
    /// for a zoom), so the container covers what the zoomed pane covers: a click anywhere on it reaches
    /// it, and AppKit sees all of it (its visible rect, tracking areas and cursor rects stop at the
    /// container's frame). The unzoom puts the area's window back.
    @Test func aZoomedAreaPaneTakesClicksOverAllOfItsFrame() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let w = try Window(renderServer: true)
        w.root.context.reduceMotionOverride = true
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        let host = try #require(w.root.context.hosts["p1"])
        let window = w.root.convert(container.frame, from: container.superview)
        w.show(.splits(.leaf("p1")), zoomed: true)
        try #require(screen.zoomMotion.pane == nil, "the zoom did not land")
        #expect(host.superview === container, "the zoom moved p1's host")
        let zoomed = try #require(w.root.frame(of: "p1"))
        let local = CGPoint(x: (max(window.maxX, zoomed.minX) + zoomed.maxX) / 2, y: zoomed.midY)
        try #require(zoomed.contains(local) && !window.contains(local), "the zoomed pane reaches past the area's window")
        let hit = try #require(w.hit(at: w.root.convert(local, to: nil)), "a click on the zoomed pane reached nothing")
        #expect(hit === host || hit.isDescendant(of: host), "hit \(hit)")
        let visible = host.visibleRect
        #expect(abs(visible.width - host.bounds.width) < 0.5 && abs(visible.height - host.bounds.height) < 0.5,
                "AppKit sees \(visible) of the zoomed host \(host.bounds)")
        w.show(w.layout)
        try #require(screen.zoomMotion.pane == nil, "the unzoom did not land")
        #expect(container.frame == screen.displayedAreaWindow(w.area), "the area's window is back: \(container.frame)")
        #expect(container.clipsSubviews)
    }

    /// An area in a column's row moves between the strip container and its row's container when the rows
    /// start or stop overflowing the column; the pane focused in it keeps the window's first responder.
    @Test func aRowChangeThatMovesTheAreasContainerKeepsTheFocusedPanesKeys() throws {
        let w = try Window(renderServer: true, rows: true) { _ in
            StripClipLayerStructureTests.Responder(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        try #require(screen.scrollerContainer(.row("c1")) == nil, "the rows fit their column")
        #expect(container.superview === screen.stripContainer)
        let responder = try #require(w.provider.views["p1"] as? StripClipLayerStructureTests.Responder)
        try #require(w.window.makeFirstResponder(responder), "the test view did not take the keys")
        w.show(Window.layout(rowHeight: 800))
        let rows = try #require(screen.scrollerContainer(.row("c1")), "the rows do not overflow their column")
        #expect(container.superview === rows, "the area's container is not in its row's")
        #expect(w.window.firstResponder === responder, "the focused view lost the keys when the rows started to overflow")
        w.show(Window.layout(rowHeight: 500))
        #expect(screen.scrollerContainer(.row("c1")) == nil, "the rows still overflow")
        #expect(container.superview === screen.stripContainer, "the area's container did not come back to the strip's")
        #expect(w.window.firstResponder === responder, "the focused view lost the keys when the rows stopped overflowing")
    }
}
