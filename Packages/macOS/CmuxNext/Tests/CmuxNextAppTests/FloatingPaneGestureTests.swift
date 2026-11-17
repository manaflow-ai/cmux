import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A pointer's resize of a floating pane and the content of the pane; what a press, a release and a focus send.
///
/// A resize of a floating pane is a resize drag of its screen: the content of the pane that follows a drag its own
/// way (`PaneResizeGestureFollowing`: a terminal, a page) hears the start at the first move and the end when the
/// release's layout landed, as for a divider. A move of the pane changes no size, so it tells nothing. A press and
/// a release with no move send no frame. A focus on a floating pane that is behind another one sends no frame.
/// Frames step at a fixed 120 Hz dt, so each assert is about a frame, not about wall time.
@MainActor @Suite(.closesItsWindows) struct FloatingPaneGestureTests {
    final class Follower: NSView, PaneResizeGestureFollowing {
        var heard: [Bool] = []
        var releases = 0
        /// The pane host's frame when `false` came.
        var frameAtEnd: CGRect?
        func paneResizeGestureDidChange(active: Bool) {
            heard.append(active)
            if !active { frameAtEnd = superview?.superview?.frame }
        }

        func paneResizeGestureReleased() { releases += 1 }
    }

    final class Panes: LayoutPaneContentProvider {
        let follower = Follower()
        func makeContentView(for pane: PaneID) -> NSView { pane == "f" ? follower : NSView() }
    }

    static let dt = 1.0 / 120
    static let two = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    static func floating(_ pane: PaneID, x: CGFloat = 0.3) -> LayoutFloatingPane {
        LayoutFloatingPane(pane: pane, frame: CGRect(x: x, y: 0.2, width: 0.3, height: 0.4))
    }

    /// One screen with 2 tiled panes and its floating panes, in a window with its motion on; the test is the clock.
    /// The content of the floating pane `f` follows a resize drag.
    @MainActor final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Each intent that the model sent.
        var intents: [LayoutIntent] = []

        init(size: CGSize = CGSize(width: 1200, height: 800), floating: [LayoutFloatingPane]) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(FloatingPaneGestureTests.two), floating: floating)],
                                activeScreenID: "s", focusedPane: "p1")
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
        var follower: Follower { provider.follower }

        /// The frame intents that the model sent.
        var frameIntents: [LayoutIntent] {
            intents.filter { if case .setFloatingFrame = $0 { true } else { false } }
        }

        /// The daemon's next state of the screen: the same tiled panes with another floating list.
        func show(floating: [LayoutFloatingPane]) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(FloatingPaneGestureTests.two), floating: floating)])
            root.syncWithModel()
        }

        @discardableResult
        func step() -> Bool { root.advanceFrame(FloatingPaneGestureTests.dt) }

        func settle() {
            for _ in 0..<600 where step() {}
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

        /// A point on the right edge of `pane`'s card (the window's coordinates).
        func rightEdge(of pane: PaneID) throws -> CGPoint {
            let card = try #require(screen.geometry.floatingCards[pane])
            return screen.convert(CGPoint(x: card.maxX - 1, y: card.midY), to: nil)
        }
    }

    /// A resize of a floating pane by its right edge: the content hears the start one time, at the first move; it
    /// hears the release in the event of the release; it hears the end one time, with the pane at its last frame.
    @Test func aResizeOfAFloatingPaneTellsItsContentAtTheFirstMoveAndWhenTheReleaseLanded() throws {
        let fixture = Screen(floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let card = try #require(screen.geometry.floatingCards["f"])
        let press = try fixture.rightEdge(of: "f")

        try screen.handleFloatingDrag("f", .began(.right), event: fixture.pointer(.leftMouseDown, at: press))
        #expect(fixture.follower.heard.isEmpty, "the press alone told \(fixture.follower.heard)")
        for step in 1...10 {
            let point = CGPoint(x: press.x + CGFloat(step) * 8, y: press.y)
            try screen.handleFloatingDrag("f", .moved, event: fixture.pointer(.leftMouseDragged, at: point))
            fixture.step()
        }
        #expect(fixture.follower.heard == [true], "the content hears the start one time, at the first move")
        #expect(fixture.follower.releases == 0, "no release before the pointer lets go")
        let wide = try #require(screen.geometry.floatingCards["f"])
        #expect(abs(wide.width - card.width - 80) < 1, "the card's right edge follows the pointer: \(card) to \(wide)")

        try screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: CGPoint(x: press.x + 80, y: press.y)))
        #expect(fixture.follower.releases == 1, "the content hears the release in the event of the release")
        fixture.settle()
        #expect(fixture.follower.heard == [true, false], "the content hears the end one time")
        let host = try #require(fixture.root.context.hosts["f"])
        #expect(fixture.follower.frameAtEnd == host.frame, "the content heard the end before the pane had its last frame")
        #expect(fixture.frameIntents.count == 1, "the release sends the frame one time: \(fixture.frameIntents)")
    }

    /// A move of a floating pane by its bar changes no size: the content hears no resize drag.
    @Test func aMoveOfAFloatingPaneTellsItsContentNoResize() throws {
        let fixture = Screen(floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let press = try fixture.bar(of: "f"), release = CGPoint(x: press.x + 120, y: press.y)

        try screen.handleFloatingDrag("f", .began(.move), event: fixture.pointer(.leftMouseDown, at: press))
        try screen.handleFloatingDrag("f", .moved, event: fixture.pointer(.leftMouseDragged, at: release))
        fixture.step()
        try screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: release))
        fixture.settle()
        #expect(fixture.follower.heard.isEmpty, "a move told the content of a resize: \(fixture.follower.heard)")
        #expect(fixture.follower.releases == 0)
        #expect(fixture.frameIntents.count == 1, "the release sends the frame one time: \(fixture.frameIntents)")
    }

    /// A floating pane that leaves its screen while a pointer resizes it: the content that heard the start hears
    /// the end, and the late release of the pointer sends no frame.
    @Test func aFloatingPaneThatLeavesInAResizeEndsTheDragForItsContent() throws {
        let fixture = Screen(floating: [Self.floating("f")])
        defer { fixture.window.closeAfterTest() }
        let screen = fixture.screen
        let press = try fixture.rightEdge(of: "f"), dragged = CGPoint(x: press.x + 40, y: press.y)

        try screen.handleFloatingDrag("f", .began(.right), event: fixture.pointer(.leftMouseDown, at: press))
        try screen.handleFloatingDrag("f", .moved, event: fixture.pointer(.leftMouseDragged, at: dragged))
        fixture.step()
        #expect(fixture.follower.heard == [true], "the content hears the start at the first move")

        fixture.show(floating: [])
        fixture.settle()
        #expect(fixture.follower.heard == [true, false], "the content hears the end when its pane left")
        try screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: dragged))
        #expect(fixture.frameIntents.isEmpty, "the late release sent \(fixture.frameIntents)")
    }

    /// A press and a release with no move between them, on the bar and on a corner: no frame goes out. The window's
    /// pane area is no round number, so the card (its edges are on the pixel grid) is not exactly the model's frame.
    @Test func aPressAndAReleaseWithNoMoveSendNoFrame() throws {
        for zone in [FloatingPaneCardView.Zone.move, .bottomRight] {
            let frame = CGRect(x: 0.31, y: 0.23, width: 0.37, height: 0.41)
            let fixture = Screen(size: CGSize(width: 1001, height: 701), floating: [LayoutFloatingPane(pane: "f", frame: frame)])
            defer { fixture.window.closeAfterTest() }
            let screen = fixture.screen
            let card = try #require(screen.geometry.floatingCards["f"])
            try #require(LayoutFloatingPane.fractions(of: card, in: screen.bounds.size) != frame,
                         "the fixture: the card on the pixel grid is not exactly the model's frame")
            let press = try fixture.bar(of: "f")

            try screen.handleFloatingDrag("f", .began(zone), event: fixture.pointer(.leftMouseDown, at: press))
            // A drag event with no distance is no move.
            try screen.handleFloatingDrag("f", .moved, event: fixture.pointer(.leftMouseDragged, at: press))
            try screen.handleFloatingDrag("f", .ended, event: fixture.pointer(.leftMouseUp, at: press))
            fixture.settle()
            #expect(fixture.frameIntents.isEmpty, "a press with no move (\(zone)) sent \(fixture.frameIntents)")
            #expect(fixture.follower.heard.isEmpty, "a press with no move (\(zone)) told the content of a resize")
            #expect(fixture.model.screens.first?.floating.first?.frame == frame, "the model keeps its exact frame (\(zone))")
        }
    }

    /// A focus by a key on a floating pane that is behind another one sends no frame: a frame of this model can be
    /// older than the frame that another client gave the pane. A focus on the front pane sends no frame also.
    @Test func aFocusByAKeyOnAFloatingPaneBehindAnotherSendsNoFrame() throws {
        let fixture = Screen(floating: [Self.floating("f"), Self.floating("g", x: 0.5)])
        defer { fixture.window.closeAfterTest() }

        fixture.model.focus("f", source: .keyboard)
        #expect(fixture.model.focusedPane == "f")
        #expect(fixture.frameIntents.isEmpty, "the focus on the pane behind sent a frame: \(fixture.frameIntents)")

        fixture.intents = []
        fixture.model.focus("g", source: .keyboard)
        #expect(fixture.frameIntents.isEmpty, "the focus on the front pane sent a frame: \(fixture.frameIntents)")
    }
}
