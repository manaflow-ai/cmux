import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the ground under a pane that moves, whatever holds the pane.
///
/// A pane that moves shows under its content what is under it at rest. A strip pane and a pane of a column at the
/// screen's edge in the `docked` mode have the window's sheet there. A pane of a column in the `overlay` mode has
/// the opaque ground of the column's backdrop. So a pane of such a column that moves shows nothing of a pane under
/// it, as a strip pane does. The motion gives each pane host's layer the colour that it had back: at the motion's
/// end, when a change of the screen's size ends the motion, and when the window stops being opaque.
extension PaneCommitMotionTests {
    /// Two strip columns and a column at the right edge in `mode`, with `chat` above `notes` in it (`rows`) or with
    /// `chat` alone; with `pane`, that pane alone on its screen (a zoom).
    static func dockRows(_ mode: DockMode, rows: Bool = true, zoomedOn pane: PaneID? = nil) -> [LayoutScreen] {
        let both = SplitNode.split(SplitID("rows"), axis: .vertical, ratio: 0.5, a: .leaf("chat"), b: .leaf("notes"))
        let columns = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "dock", width: 0.3, root: rows ? both : .leaf("chat"), dock: DockColumn(edge: .right, mode: mode)),
        ])
        let layout = pane.map { ScreenLayout.splits(.leaf($0)) } ?? columns
        return [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: pane != nil)]
    }

    /// A close of the lower one of 2 panes of a column at the screen's edge. The other pane of the column grows over
    /// the pane that left: at the start, at each quarter and at the end of its move the screen shows nothing of that
    /// pane in its rect, also not through its tab row.
    @Test(arguments: dockModes)
    func aCloseInAColumnAtTheEdgeShowsNoPaneUnderThePaneThatGrows(_ mode: String) throws {
        let dock = try #require(DockMode(rawValue: mode), "SETUP: no dock mode \(mode)")
        let harness = Commit.Harness(Self.dockRows(dock), focused: "notes", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let left = try #require(harness.root.context.hosts["notes"], "SETUP: the pane that the close takes out has no host")
        harness.model.apply(screens: Self.dockRows(dock, rows: false))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let host = try #require(harness.root.context.hosts["chat"], "SETUP: the pane that stays has no host")
        let move = try #require(host.layer.map { Self.move(of: $0) }, "SETUP: the pane that stays has no layer")
        try #require(move.moves && left.isLeaving && !left.isHidden, "SETUP: the pane that stays does not move, or the move does not keep the pane that left")
        for part in Self.quarters {
            let over = move.rect(at: part)
            let seen = Self.kept(left, on: screen, over: [host], at: part)
            #expect(seen.area(in: over) < 1 && seen.through < 1,
                    "at \(part) of the close's move the screen shows \(seen.area(in: over)) pt2 of the pane that left in the rect \(over) of the pane that grows, \(seen.through) pt2 through it")
        }
    }

    /// A zoom of the pane of a column at the screen's edge, then the unzoom at rest: the pane closes back to its
    /// column over the strip panes that come back. At the start, at each quarter and at the end of its move the
    /// screen shows none of them in its rect, also not through its tab row.
    @Test(arguments: dockModes)
    func anUnzoomBackIntoAColumnAtTheEdgeShowsNoPaneUnderItsPane(_ mode: String) throws {
        let dock = try #require(DockMode(rawValue: mode), "SETUP: no dock mode \(mode)")
        let harness = Commit.Harness(Self.dockRows(dock, rows: false), focused: "chat", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Self.dockRows(dock, rows: false, zoomedOn: "chat"))
        harness.root.syncWithModel()
        Commit.rest(harness)
        try #require(!Self.inFlight(screen), "SETUP: the zoom did not come to rest")
        let host = try #require(harness.root.context.hosts["chat"], "SETUP: the zoomed pane has no host")
        let content = try #require(harness.provider.contents["chat"], "SETUP: the zoomed pane has no content")
        let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        last.autoresizingMask = [.width, .height]
        area.addSubview(last)
        content.addSubview(area)
        harness.model.apply(screens: Self.dockRows(dock, rows: false))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let move = try #require(host.layer.map { Self.move(of: $0) }, "SETUP: the unzoom's pane has no layer")
        let others = Self.stack(on: screen).filter { $0 !== host }
        try #require(move.moves && others.count == 2, "SETUP: the unzoom's pane does not move over the 2 panes that come back (\(others.count) show)")
        for part in Self.quarters {
            let over = move.rect(at: part)
            for other in others {
                let seen = Self.kept(other, on: screen, over: [host], at: part)
                #expect(seen.area(in: over) < 1 && seen.through < 1,
                        "at \(part) of the unzoom's move the screen shows \(seen.area(in: over)) pt2 of \(other.pane) in the rect \(over) of the pane that closes over it, \(seen.through) pt2 through it")
            }
        }
    }

    /// The window stops being opaque in a move (it gets a see-through background): the pass of the next act takes the
    /// colour from each pane that has it, the panes of the act before too. No pane keeps a plain colour over a window
    /// that shows what is behind it.
    @Test func afterTheWindowStopsBeingOpaqueInAMoveTheNextActTakesEachColourAway() throws {
        let scene = try Self.closeThenSplit(seeThrough: true)
        defer { scene.alone.harness.window.closeAfterTest() }
        let coloured = scene.alone.screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.layer?.backgroundColor != nil }.map(\.pane)
        #expect(coloured.isEmpty, "after the window stopped being opaque the panes \(coloured) keep a colour on their layer")
    }

    /// A pane host whose layer has a colour of its own before the act: in the move it has the window's colour, and
    /// after the motion's end it has its own colour again, not none.
    @Test func aPaneLayerThatHadAColourGetsItBackAtTheMotionsEnd() throws {
        let harness = Commit.Harness(Commit.pair, focused: Commit.right, holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let layer = try #require(harness.root.context.hosts[Commit.right]?.layer, "SETUP: the pane that stays has no layer")
        let own = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).cgColor
        layer.backgroundColor = own
        harness.model.apply(screens: Commit.screen(.leaf(Commit.right)))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.inFlight(screen), "SETUP: no pane moves at the close")
        #expect(Self.rgba(layer.backgroundColor) == Self.rgba(Self.sheet(of: screen)),
                "in the close's move the pane has \(String(describing: Self.rgba(layer.backgroundColor))) under its content; the window has \(String(describing: Self.rgba(Self.sheet(of: screen))))")
        Commit.rest(harness)
        try #require(!Self.inFlight(screen), "SETUP: the close's move did not come to rest")
        #expect(Self.rgba(layer.backgroundColor) == Self.rgba(own),
                "after the motion's end the pane's layer has \(String(describing: Self.rgba(layer.backgroundColor))); before the act it had \(String(describing: Self.rgba(own)))")
    }

    /// A change of the screen's size in a move ends the motion in that turn: the pane that moved has no colour on its
    /// layer from then, as after a motion that ran to its end.
    @Test func aChangeOfTheScreensSizeInAMoveTakesTheColourAway() throws {
        let alone = try Self.alone(zoomed: false)
        defer { alone.harness.window.closeAfterTest() }
        let layer = try #require(alone.host.layer, "SETUP: the pane that moves has no layer")
        try #require(layer.backgroundColor != nil, "SETUP: the pane that moves has no colour in the close's move")
        alone.harness.window.setContentSize(NSSize(width: 1400, height: 900))
        alone.harness.root.layoutSubtreeIfNeeded()
        #expect(!Self.inFlight(alone.screen), "the motion goes on after the change of the screen's size")
        #expect(layer.backgroundColor == nil, "after the change of the screen's size the pane keeps the colour \(String(describing: Self.rgba(layer.backgroundColor))) on its layer")
    }

    /// What is under a floating pane at rest is its card. With a card of one opaque colour (a look with no
    /// see-through background and no tint) the floating pane's ground is that colour. With a see-through look, and
    /// with a tint, the card is no plain colour: the pane has no ground. No act of a tiled pane moves a floating
    /// pane, so this row reads the answer of the function that the pass of each act asks for each pane's ground
    /// (`PaneCommitMotion.ground(under:on:sheet:)`).
    @Test func aFloatingPanesGroundIsItsCardsColourWhenTheCardIsOnePlainColour() throws {
        let floating = LayoutFloatingPane(pane: "f", frame: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5))
        let screens = [LayoutScreen(id: "s", name: "s", layout: .splits(Self.tree(2)), floating: [floating])]
        let harness = Commit.Harness(screens, focused: "p", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let host = try #require(harness.root.context.hosts["f"], "SETUP: the floating pane has no host")
        let card = try #require(screen.floatState.cards["f"], "SETUP: the floating pane has no card")
        let sheet = Self.sheet(of: screen).map { PaneCommitMotion.Sheet.color($0) }
        func ground() -> CGColor? {
            if case .color(let color)? = PaneCommitMotion.ground(under: host, on: screen, sheet: sheet) { return color }
            return nil
        }
        var look = FloatingPaneLook()
        look.backgroundOpacity = 0.5
        card.show(look: look, corners: card.corners)
        let seeThrough = ground()
        #expect(seeThrough == nil, "under a card with a see-through look the floating pane's ground is \(String(describing: Self.rgba(seeThrough)))")
        look.backgroundOpacity = 1
        look.tintStrength = 0.3
        card.show(look: look, corners: card.corners)
        let tinted = ground()
        #expect(tinted == nil, "under a card with a tint the floating pane's ground is \(String(describing: Self.rgba(tinted)))")
        look.tintStrength = 0
        card.show(look: look, corners: card.corners)
        let plain = ground()
        #expect((plain?.alpha ?? 0) >= 1 && Self.rgba(plain) == Self.rgba(card.solidGround),
                "under a card of one opaque colour the floating pane's ground is \(String(describing: Self.rgba(plain))); the card shows \(String(describing: Self.rgba(card.solidGround)))")
    }
}
