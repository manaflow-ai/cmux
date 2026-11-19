import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The motion and the order of the views of a screen with floating panes.
///
/// A floating pane shows at its place at once: it has no spring of its own. It also stops no spring of a tiled
/// pane: a tiled pane on a spring (a ratio change) goes on when a floating pane moves or comes to the front, by
/// the model or by the pointer. A zoom and an unzoom show as on each other screen, in one pass. The views are in
/// one order: the tiled panes, the docked columns and the scroll bar, then each floating pane's card with its pane
/// above it, back to front.
/// Frames step at a fixed 120 Hz dt, so each assert is about a frame, not about wall time.
@MainActor @Suite(.closesItsWindows) struct FloatingPaneMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120
    static let two = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// The same split at another ratio: the same structure, so the change springs.
    static let uneven = SplitNode.split("h", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))

    static func floating(_ pane: PaneID, x: CGFloat = 0.3) -> LayoutFloatingPane {
        LayoutFloatingPane(pane: pane, frame: CGRect(x: x, y: 0.2, width: 0.3, height: 0.4))
    }

    /// One screen in a window of 1200 by 800 with its motion on; the test is the clock.
    @MainActor final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ layout: ScreenLayout, floating: [LayoutFloatingPane]) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout, floating: floating)],
                                activeScreenID: "s", focusedPane: "p1")
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        /// The daemon's next state of the screen. A zoomed screen has its zoomed pane alone and no floating list.
        func show(_ layout: ScreenLayout, zoomed: Bool = false, floating: [LayoutFloatingPane]) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: zoomed, floating: floating)])
            root.syncWithModel()
        }

        @discardableResult
        func step() -> Bool { root.advanceFrame(FloatingPaneMotionTests.dt) }

        func settle() {
            for _ in 0..<600 where step() {}
        }

        /// The place of `view` in the order of the screen's views, back to front.
        func order(of view: NSView?) throws -> Int {
            let view = try #require(view)
            return try #require(screen.subviews.firstIndex(where: { $0 === view }))
        }

        /// The split gets another ratio; after 3 frames the left pane is on its spring to its new width.
        func startARatioSpring(floating: [LayoutFloatingPane]) throws {
            show(.splits(FloatingPaneMotionTests.uneven), floating: floating)
            for _ in 0..<3 { step() }
            let frame = try #require(screen.paneFrames["p1"])
            try #require(frame.rect != frame.targetRect, "the ratio's spring is in the air: \(frame.rect) to \(frame.targetRect)")
        }

        /// Whether the left pane is at the place of its target.
        func leftPaneIsAtRest() throws -> Bool {
            let frame = try #require(screen.paneFrames["p1"])
            return frame.rect == frame.targetRect
        }

        /// A pointer event at `point` (the window's coordinates).
        func pointer(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        /// A point on the bar of `pane`'s card (the window's coordinates).
        func bar(of pane: PaneID) throws -> CGPoint {
            let card = try #require(screen.geometry.floatingCards[pane])
            return screen.convert(CGPoint(x: card.midX, y: card.minY + 4), to: nil)
        }
    }

    /// A floating pane that moves: it is at its new place at once, and the tiled pane on a spring goes on.
    @Test func aMoveOfAFloatingPaneSnapsNoTiledSpring() throws {
        let fixture = Screen(.splits(Self.two), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let before = try #require(screen.geometry.floatingCards["f"])
        try fixture.startARatioSpring(floating: [Self.floating("f")])

        fixture.show(.splits(Self.uneven), floating: [Self.floating("f", x: 0.5)])
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring after the floating pane moved")
        let moved = try #require(screen.geometry.floatingCards["f"])
        #expect(moved.minX > before.minX + 100, "the floating pane has a new place: \(before) to \(moved)")
        let pane = try #require(screen.paneFrames["f"])
        #expect(pane.targetRect == LayoutFloatingPane.paneRect(inCard: moved), "the floating pane's place is inside its card")
        #expect(pane.rect == pane.targetRect, "the floating pane is at its new place at once: \(pane.rect) to \(pane.targetRect)")
        fixture.settle()
        #expect(try fixture.leftPaneIsAtRest(), "the ratio change lands")
        #expect(screen.paneFrames["f"]?.rect == pane.targetRect, "the floating pane stays at its new place")
    }

    /// A floating pane that comes to the front: its card and its pane are above the other floating pane, and the
    /// tiled pane on a spring goes on.
    @Test func aRaiseOfAFloatingPaneSnapsNoTiledSpring() throws {
        let first = Self.floating("f1"), second = Self.floating("f2", x: 0.4)
        let fixture = Screen(.splits(Self.two), floating: [first, second])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        try fixture.startARatioSpring(floating: [first, second])

        fixture.show(.splits(Self.uneven), floating: [second, first])
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring after the floating pane came to the front")
        let views: [NSView?] = [screen.floatState.cards["f2"], fixture.root.context.hosts["f2"], screen.floatState.cards["f1"],
                                fixture.root.context.hosts["f1"]]
        let order = try views.map { try fixture.order(of: $0) }
        #expect(order == order.sorted(), "back to front: the card and the pane of f2, then the card and the pane of f1: \(order)")
        fixture.settle()
        #expect(try fixture.leftPaneIsAtRest(), "the ratio change lands")
        let landed = try views.map { try fixture.order(of: $0) }
        #expect(landed == landed.sorted(), "the order stays after the landing: \(landed)")
    }

    /// A pointer's drag of a floating pane by its bar: the pane follows the pointer at once, and the tiled pane on a
    /// spring goes on, during the drag and after the release.
    @Test func aDragOfAFloatingPaneSnapsNoTiledSpring() throws {
        let fixture = Screen(.splits(Self.two), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let card = try #require(screen.geometry.floatingCards["f"])
        try fixture.startARatioSpring(floating: [Self.floating("f")])

        let press = try fixture.bar(of: "f"), release = CGPoint(x: press.x + 120, y: press.y)
        try screen.handleFloatingDrag("f", .began(.move), event: fixture.pointer(.leftMouseDown, at: press))
        try screen.handleFloatingDrag("f", .moved, event: fixture.pointer(.leftMouseDragged, at: release))
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring during the drag")
        let dragged = try #require(screen.geometry.floatingCards["f"])
        #expect(abs(dragged.minX - card.minX - 120) < 1, "the card follows the pointer: \(card) to \(dragged)")
        let pane = try #require(screen.paneFrames["f"])
        #expect(pane.rect == pane.targetRect, "the floating pane follows the pointer at once: \(pane.rect) to \(pane.targetRect)")

        try screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: release))
        fixture.root.syncWithModel()
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring after the release")
        fixture.settle()
        #expect(try fixture.leftPaneIsAtRest(), "the ratio change lands")
        let landed = try #require(screen.geometry.floatingCards["f"])
        #expect(abs(landed.minX - card.minX - 120) < 1, "the card stays where the pointer left it: \(card) to \(landed)")
    }

    /// A press and a release on the bar of a floating pane with no move between them: the tiled pane on a spring
    /// goes on.
    @Test func aPressOnTheBarOfAFloatingPaneSnapsNoTiledSpring() throws {
        let fixture = Screen(.splits(Self.two), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        try fixture.startARatioSpring(floating: [Self.floating("f")])

        let press = try fixture.bar(of: "f")
        try fixture.screen.handleFloatingDrag("f", .began(.move), event: fixture.pointer(.leftMouseDown, at: press))
        try fixture.screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: press))
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring after the release")
        fixture.root.syncWithModel()
        #expect(try !fixture.leftPaneIsAtRest(), "the tiled pane is still on its spring after the model's update")
        fixture.settle()
        #expect(try fixture.leftPaneIsAtRest(), "the ratio change lands")
    }

    /// A zoom and an unzoom on a screen with a floating pane show as on each other screen, in one pass: no card
    /// while the screen is zoomed; after the unzoom the card and its pane are back at once, above the tiled panes.
    @Test func aZoomAndAnUnzoomOnAScreenWithAFloatingPaneShowInOnePass() throws {
        let fixture = Screen(.splits(Self.two), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let slot = try #require(screen.paneFrames["p1"]?.targetRect)
        let place = try #require(screen.paneFrames["f"]?.targetRect)

        fixture.show(.splits(.leaf("p1")), zoomed: true, floating: [])
        let full = try #require(screen.paneFrames["p1"])
        #expect(full.targetRect != slot, "the zoomed pane's place is not its slot: \(full.targetRect)")
        #expect(full.rect == full.targetRect, "the zoom has no spring: \(full.rect) to \(full.targetRect)")
        #expect(screen.paneFrames["f"] == nil, "a zoomed screen has no place for the floating pane")
        fixture.settle()
        #expect(screen.floatState.cards["f"] == nil, "a zoomed screen has no card")

        fixture.show(.splits(Self.two), floating: [Self.floating("f")])
        let back = try #require(screen.paneFrames["p1"])
        #expect(back.targetRect == slot, "the pane's place after the unzoom is its slot: \(back.targetRect)")
        #expect(back.rect == back.targetRect, "the unzoom has no spring: \(back.rect) to \(back.targetRect)")
        let pane = try #require(screen.paneFrames["f"])
        #expect(pane.rect == place && pane.targetRect == place, "the floating pane is back at its place at once: \(pane.rect)")
        fixture.settle()
        let card = try fixture.order(of: screen.floatState.cards["f"]), host = try fixture.order(of: fixture.root.context.hosts["f"])
        for tiled in ["p1", "p2"] as [PaneID] {
            let under = try fixture.order(of: fixture.root.context.hosts[tiled])
            #expect(under < card && card < host, "\(tiled), then the card, then the floating pane: \(under), \(card), \(host)")
        }
    }

    /// The view of the dim around a zoom in the overlay plane of `fixture`'s root, when one shows.
    static func dim(of fixture: Screen) -> NSView? {
        fixture.root.overlayPlane.subviews.first { $0.identifier?.rawValue == "pane.zoom.dim" }
    }

    /// The dim around a zoom hears the change of the tiled layout only. The zoom of the only tiled pane of a screen
    /// with a floating pane changes no tiled structure: no pane moves, so it brings no dim, and the floating pane that
    /// goes with the zoom is no cause for one. The fixture asks for the panes' move, with which a zoom's dim comes.
    /// The control shows that a dim can show in this fixture: the unzoom of one of 2 tiled panes brings one.
    @Test func theZoomOfTheOnlyTiledPaneOfAScreenWithAFloatingPaneBringsNoDim() throws {
        let control = Screen(.splits(Self.two), floating: [])
        defer { control.window.closeAfterTest() }
        try #require(control.screen.zoomDim.fade(on: control.screen) > 0, "SETUP: the dim has no fade in this fixture")
        control.show(.splits(.leaf("p1")), zoomed: true, floating: [])
        control.settle()
        control.show(.splits(Self.two), floating: [])
        control.step()
        try #require(control.screen.zoomDim.phase == .going && Self.dim(of: control) != nil,
                     "SETUP: the unzoom of one of 2 tiled panes brings no dim in this fixture")
        control.settle()

        let fixture = Screen(.splits(.leaf("p1")), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        fixture.root.context.commitMotionOverride = true
        let screen = fixture.screen
        try #require(screen.floatState.cards["f"] != nil, "SETUP: the floating pane has no card")
        fixture.show(.splits(.leaf("p1")), zoomed: true, floating: [])
        #expect(screen.zoomDim.phase == .off, "the zoom of the only tiled pane brings a dim: \(screen.zoomDim.phase)")
        #expect(Self.dim(of: fixture) == nil, "a dim is in the overlay plane in the turn of the zoom")
        for tick in 1...60 {
            fixture.step()
            #expect(Self.dim(of: fixture) == nil, "tick \(tick): a dim shows after the zoom of the only tiled pane")
        }
        #expect(screen.floatState.cards["f"] == nil, "a zoomed screen has no card")
    }

    /// In the turn of a zoom key the floating pane and its card stay as they show, as the tiled pane that the zoom
    /// covers does. They go together with that pane, in the frame that shows the zoom: no frame has the card without
    /// its pane, and no frame has the floating pane over the zoomed pane. A zoom that takes a floating pane with it
    /// shows in one frame, with no dim and no move of a pane, also when the fixture asks for the panes' move.
    @Test func aFloatingPaneAndItsCardStayInTheTurnOfAZoomKeyAndGoInTheFrameThatShowsTheZoom() throws {
        let fixture = Screen(.splits(Self.two), floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        fixture.root.context.commitMotionOverride = true
        let screen = fixture.screen
        // The views, read before the zoom: the zoom takes the panes that it covers out of the layout's hosts.
        let card = try #require(screen.floatState.cards["f"], "SETUP: the floating pane has no card")
        let pane = try #require(fixture.root.context.hosts["f"], "SETUP: the floating pane has no host")
        let covered = try #require(fixture.root.context.hosts["p2"], "SETUP: the pane that the zoom covers has no host")

        fixture.show(.splits(.leaf("p1")), zoomed: true, floating: [])
        // The turn of the key: nothing went.
        #expect(card.superview === screen && !card.isHidden, "the card went in the turn of the zoom key")
        #expect(pane.superview === screen && !pane.isHidden, "the floating pane went in the turn of the zoom key")
        #expect(!covered.isHidden, "the tiled pane that the zoom covers went in the turn of the zoom key")
        #expect(Self.dim(of: fixture) == nil, "a dim is in the overlay plane in the turn of the zoom key")

        var shownAt: Int?
        for tick in 1...8 {
            fixture.step()
            #expect(Self.dim(of: fixture) == nil, "tick \(tick): a dim shows at a zoom that takes a floating pane with it")
            #expect(!PaneCommitMotionTests.inFlight(screen), "tick \(tick): a pane has a move on its layer at a zoom that takes a floating pane with it")
            if covered.isHidden {
                // The frame that shows the zoom: the floating pane and its card go with the covered pane.
                #expect(pane.isHidden, "tick \(tick) shows the zoom with the floating pane over it")
                #expect(card.superview == nil && screen.floatState.cards["f"] == nil, "tick \(tick) shows the zoom with the card")
                shownAt = tick
                break
            }
            #expect(card.superview === screen && !card.isHidden, "tick \(tick): the card went before the zoom showed")
            #expect(pane.superview === screen && !pane.isHidden, "tick \(tick): the floating pane went before the zoom showed")
        }
        _ = try #require(shownAt, "the zoom did not show in 8 frames")
    }

    /// Two strip columns, a docked column on the right and 2 floating panes that lie over each other.
    static func withADock() -> Screen {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
            LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
        ])
        return Screen(layout, floating: [floating("f1"), floating("f2", x: 0.4)])
    }

    /// The order of the views: each view that is not of a floating pane, then the card and the pane of the first
    /// floating pane, then the card and the pane of the second one.
    @Test func theViewsOfTheFloatingPanesAreAboveEachOtherViewInTheOrderOfTheList() throws {
        let fixture = Self.withADock()
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let floating: [NSView?] = [screen.floatState.cards["f1"], fixture.root.context.hosts["f1"], screen.floatState.cards["f2"],
                                   fixture.root.context.hosts["f2"]]
        let order = try floating.map { try fixture.order(of: $0) }
        #expect(order == order.sorted(), "back to front: the card and the pane of f1, then the card and the pane of f2: \(order)")
        let others = screen.subviews.enumerated().filter { entry in !floating.contains(where: { $0 === entry.element }) }
        try #require(others.count >= 4, "the 4 other panes are in the view: \(others.count) views")
        let highest = try #require(others.map(\.offset).max()), lowest = try #require(order.first)
        #expect(highest < lowest, "each other view is under the first card: \(highest), the card \(lowest)")
        for pane in ["p1", "p2", "p3", "chat"] as [PaneID] {
            let tiled = try fixture.order(of: fixture.root.context.hosts[pane])
            #expect(tiled < lowest, "\(pane) is under the first card: \(tiled), the card \(lowest)")
        }
    }

    /// A second pass with no change does no work for a floating pane: no clip is computed again and no card moves.
    @Test func aSecondPassWithNoChangeIsStillWithFloatingPanes() throws {
        let fixture = Self.withADock()
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let clips = screen.stripClipsComputed, passes = screen.presentationPasses
        _ = screen.reconcile(animated: false)
        try #require(screen.presentationPasses == passes + 1, "the pass presented: \(screen.presentationPasses - passes)")
        #expect(screen.stripClipsComputed == clips, "the second pass computed \(screen.stripClipsComputed - clips) clips again")
        #expect(!screen.presentFloatingCards(), "no card moves in a pass with no change")
        #expect(!fixture.step(), "nothing moves after it")
    }

    /// A floating pane's host is not a docked pane's: it has no dock fill. The docked column's pane has it.
    @Test func aFloatingPaneIsNotADockedPane() throws {
        let fixture = Self.withADock()
        defer { fixture.window.closeAfterTest() }
        let hosts = fixture.root.context.hosts
        let docked = try #require(hosts["chat"]), strip = try #require(hosts["p1"])
        let first = try #require(hosts["f1"]), second = try #require(hosts["f2"])
        #expect(docked.isDocked, "the docked column's pane is docked")
        #expect(!first.isDocked && !second.isDocked, "a floating pane is not docked")
        #expect(!strip.isDocked, "a strip pane is not docked")
    }
}
