import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextLayout
import CmuxNextWakeups
import CoreGraphics
import QuartzCore
import Testing

/// Scroll areas pan by translation (p04-input-050): with `motion.renderServer` on, an area's hosts and
/// dividers sit in its motion container, which clips them to the area's window (no host carries a mask
/// for it), and an area pan event sets the translation of the container's layer and of its rings'
/// plane: no host frame set, no clip recomputed, no tracking area rebuilt. A press during the pan lands
/// the area where it shows; the gesture's end lays it out once where it shows.
@MainActor @Suite(.serialized) struct ScrollAreaTests {
    /// Two half columns on a 1200 pt window (`LayoutScrollModifierTests.AreaWindow`): the first holds the
    /// chain p1 | p2 | p3, too wide for its column, so it is a scroll area; the second holds `q`.
    final class Window {
        let provider = LayoutScrollModifierTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(renderServer: Bool, input: InputEventTap? = nil, make: ((PaneID) -> NSView)? = nil) throws {
            _ = NSApplication.shared
            let chain: SplitNode = .split("s1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                          b: .split("s2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
                LayoutColumn(id: "c1", width: 0.5, root: chain),
                LayoutColumn(id: "c2", width: 0.5, root: .leaf("q")),
            ]))], activeScreenID: "s", focusedPane: "q")
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
                                                        clickCount: 1, pressure: 1))
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
        let p2 = try #require(w.root.context.hosts["p2"])
        #expect(p2.layer?.mask != nil, "p2 reaches past the window: its own mask clips it")
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
        #expect(hosts.map { $0.layer?.mask }.elementsEqual(masks, by: { $0 === $1 }), "no mask set during the pan")
        #expect(container.frame == containerFrame, "the clip stays where it is")
        #expect(w.root.overlayHostsPlaced == placed, "no overlay sync places a ring during the pan")
        #expect(contents.map(\.trackingAreaUpdates) == tracking, "no tracking area rebuilt")
        #expect(contents.map(\.cursorRectResets) == cursors, "no cursor rect rebuilt")
        #expect(container.translationSets - sets == 19, "one translation per event")
        #expect(container.chromePlane.layer?.sublayerTransform.m41 == container.translation.dx, "the rings' plane takes the same translation")
        let shownAfter = try #require(w.root.frame(of: "p2"))
        #expect(abs(shownAfter.minX - (shownBefore.minX - 80)) < 0.5, "the area shows 80 pt further: \(shownBefore) -> \(shownAfter)")
        let placedP2 = w.root.convert(screen.placedFrame(of: hosts[1]), from: screen)
        #expect(abs(placedP2.minX - shownAfter.minX) < 0.5, "p2 is placed where it shows")
        w.scroll(at: point, phase: .ended)
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

    @Test func theGestureEndLaysTheAreaOutOnceWhereItShows() throws {
        let w = try Window(renderServer: true)
        let screen = w.screen
        let container = try #require(screen.scrollerContainer(.area(w.area)))
        let point = try w.center("p1")
        w.pan(at: point, events: 10, dx: -6)
        #expect(screen.areaScrolls[w.area]?.panBase != nil, "the pan holds the area where it was laid out")
        w.scroll(at: point, phase: .ended)
        #expect(screen.areaScrolls[w.area]?.panBase == nil)
        #expect(container.translation == .zero)
        let shown = try #require(w.root.frame(of: "p2"))
        let laidOut = try w.laidOut("p2")
        #expect(abs(laidOut.minX - shown.minX) < 0.5, "laid out where it shows")
        w.settle()
        #expect(container.translation == .zero && !w.root.isLayoutInMotion)
    }
}
