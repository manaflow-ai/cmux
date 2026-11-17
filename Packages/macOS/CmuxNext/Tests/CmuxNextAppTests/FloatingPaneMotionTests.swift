import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The motion and the order of the views of a screen with floating panes.
///
/// A floating pane shows at its place at once: it has no spring of its own. It also stops no spring of a tiled
/// pane: a tiled pane on a spring (a ratio change) goes on when a floating pane moves or comes to the front. A
/// zoom and an unzoom show as on each other screen, in one pass. The views are in one order: the tiled panes, the
/// docked columns and the scroll bar, then each floating pane's card with its pane above it, back to front.
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
