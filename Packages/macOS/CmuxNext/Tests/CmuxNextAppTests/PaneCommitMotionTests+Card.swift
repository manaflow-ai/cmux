import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, where the ground of a pane that moves is.
///
/// In a chrome style with a card for each pane the panes have gaps between them, and the window shows a shade in
/// the gaps: the shade leaves out each pane's card. A pane's clip is its card there, with the card's round corners.
/// So the ground of a pane that moves is inside its clip, as the clip's lowest layer: it covers the card and nothing
/// of the gaps. In each other style a pane's cell has the window's sheet under all of it, and the ground is on the
/// cell: on the layer of the pane's host.
extension PaneCommitMotionTests {
    /// The name of the layer that is a plain ground inside a pane's card.
    static let cardGround = "pane.commit.card"

    /// The layers that the motion put into the clip of `host`: a plain ground, or a copy of the window's picture.
    static func grounds(inCardOf host: PaneHostView) -> [CALayer] {
        (host.clipView.layer?.sublayers ?? []).filter { $0.name == cardGround || $0.name == pictureCopy }
    }

    /// One close in a style with a padding, begun: the pane that stays moves.
    struct InStyle {
        let harness: Commit.Harness
        let screen: ScreenContentView
        /// The pane that stays and takes the room.
        let host: PaneHostView
        let backdrop: WindowMaterialView?
    }

    /// A close of the first one of 2 panes, in a style with a padding around each pane's content; with `cards`, in a
    /// style with a card for each pane. With `picture` the window shows a picture, else it is opaque. `own`: the
    /// clip of the pane that stays has this colour of its own before the close, as a pane of a column in the
    /// `docked` mode has the user's colour for the docks (`PaneHostView.applyDockFill`). The row puts the colour on
    /// the clip itself: it changes no setting of the whole process. `marker`: a layer that the pane has before the
    /// close, in its clip's layer with `cards`, else in its cell's layer.
    static func closeInStyle(cards: Bool, picture: Bool, own: CGColor? = nil, marker: CALayer? = nil) throws -> InStyle {
        let harness = Commit.Harness(Commit.screen(tree(2)), focused: "p", holds: false) { model in
            model.followsDesignMetrics = false
            model.baseStyle.panePadding = 6
            model.baseStyle.paneCornerRadius = 10
            model.baseStyle.floatingPanes = cards
            if cards { model.baseStyle.dividerThickness = 0 }
        }
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        let backdrop = picture ? Self.picture(under: harness) : nil
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let host = try #require(harness.root.context.hosts["pb"], "SETUP: the pane that stays has no host")
        try #require(host.wholeCard == cards, "SETUP: the clip of the pane that stays is its card: \(host.wholeCard), not \(cards)")
        try #require(!host.contentRect.isEmpty && host.contentRect != host.bounds, "SETUP: the clip \(host.contentRect) is the pane's whole cell \(host.bounds)")
        if let own { host.clipView.layer?.backgroundColor = own }
        if let marker { (cards ? host.clipView.layer : host.layer)?.addSublayer(marker) }
        let pane = try #require(harness.model.focusedPane, "SETUP: no pane has the focus")
        _ = try #require(harness.model.showPaneClose(pane), "SETUP: the model does not show the close of \(pane)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(dt)
        try #require(moves(host), "SETUP: the pane that stays does not move at the close")
        begun = true
        return InStyle(harness: harness, screen: screen, host: host, backdrop: backdrop)
    }

    /// Where the ground of a pane that moves is, over an opaque window's colour and over a window's picture.
    /// - With a card for each pane: the pane's cell has no colour and no copy, and the pane's clip has 1 layer of
    ///   the motion under each other layer of it. The clip cuts that layer to the card: it has the card's corners,
    ///   and the hole that the layout gives to the gaps' shade for this pane is the same rect with the same radius.
    ///   A plain ground has the window's colour and covers the clip. A copy shows the picture where the window has
    ///   it at the start, at each quarter and at the end of the move.
    /// - With no card: the pane's clip has no layer of the motion. The window's colour is on the layer of the
    ///   pane's host, or the copy is that layer's lowest layer.
    /// After the motion's end the pane has none of them.
    @Test(arguments: [true, false], [false, true])
    func thePanesGroundIsInItsCardWhereItsClipIsTheCardElseOnItsCell(_ cards: Bool, _ picture: Bool) throws {
        let scene = try Self.closeInStyle(cards: cards, picture: picture)
        defer { scene.harness.window.closeAfterTest() }
        let host = scene.host, screen = scene.screen
        let layer = try #require(host.layer, "SETUP: the pane's host has no layer")
        let clip = try #require(host.clipView.layer, "SETUP: the pane's clip has no layer")
        let onCell = Self.pictures(on: host), inCard = Self.grounds(inCardOf: host)
        let colour = Self.rgba(layer.backgroundColor), sheet = Self.rgba(Self.sheet(of: screen))
        let what = "\(cards ? "with a" : "with no") card for each pane, over \(picture ? "a picture" : "a colour")"
        let has = "\(onCell.count) copies and the colour \(String(describing: colour)) on its cell, \(inCard.count) layers of the motion in its clip"
        if cards {
            #expect(onCell.isEmpty && colour == nil && inCard.count == 1, "\(what), the pane that moves has \(has); its ground must be 1 layer in its clip")
        } else if picture {
            #expect(onCell.count == 1 && colour == nil && inCard.isEmpty, "\(what), the pane that moves has \(has); it must have 1 copy on its cell")
        } else {
            #expect(onCell.isEmpty && colour != nil && colour == sheet && inCard.isEmpty,
                    "\(what), the pane that moves has \(has); it must have the window's colour \(String(describing: sheet)) on its cell")
        }
        if cards, let ground = inCard.first {
            // The layer of the pane's content comes into the clip's layer at a display, and this window has none:
            // the row reads the ground's own place in the order, and each other layer that is there.
            let others = (clip.sublayers ?? []).filter { $0 !== ground }
            let lowest: Bool = clip.sublayers?.first === ground
            #expect(lowest && ground.zPosition < 0 && others.allSatisfy { $0.zPosition > ground.zPosition }, "\(what): the ground is not under each other layer of the pane's clip")
            let radius = PaneChromeGeometry.cornerRadius(for: host.contentRect, style: scene.harness.root.context.style)
            #expect(clip.masksToBounds && radius > 0 && abs(clip.cornerRadius - radius) < 0.01,
                    "\(what): the pane's clip has the corner radius \(clip.cornerRadius) and cuts its layers: \(clip.masksToBounds); the card's radius is \(radius)")
            let card = host.cardInWindow, holes = scene.harness.root.paneCardsInWindow
            #expect(holes.contains { Commit.near($0.rect, card) && abs($0.radius - clip.cornerRadius) < 0.01 },
                    "\(what): no hole of the gaps' shade is the card \(card) with the clip's radius \(clip.cornerRadius): \(holes)")
            #expect(Commit.near(host.convert(host.clipView.frame, to: nil), card), "\(what): the pane's clip is not its card \(card)")
            #expect(ground.name == (picture ? Self.pictureCopy : Self.cardGround), "\(what): the ground in the clip is the layer \(ground.name ?? "with no name")")
            if !picture {
                // A clip whose content is held is larger at the move's start than at its end: the ground covers both.
                let room = clip.bounds.union(CGRect(origin: clip.bounds.origin, size: Self.move(of: layer).start.size))
                #expect(Self.rgba(ground.backgroundColor) == sheet && ground.frame.insetBy(dx: -0.51, dy: -0.51).contains(room),
                        "\(what): the ground has the colour \(String(describing: Self.rgba(ground.backgroundColor))) at \(ground.frame); the window has \(String(describing: sheet)), the clip shows \(room) in the move")
            }
        }
        if picture, let copy = cards ? inCard.first : onCell.first, let art = scene.backdrop?.artView {
            let want = art.convert(art.bounds, to: nil)
            for part in Self.quarters {
                let shows = Self.windowRect(of: copy, on: host, in: screen, at: { _ in part }) ?? .zero
                #expect(Commit.near(shows, want), "\(what): at \(part) of the close's move the copy shows the picture at \(shows) in the window; the window has it at \(want)")
            }
        }
        _ = Self.toTheEnd(scene.harness, screen)
        let left = Self.pictures(on: host).count + Self.grounds(inCardOf: host).count
        #expect(left == 0 && layer.backgroundColor == nil && !Self.inFlight(screen),
                "\(what): after the motion's end the pane keeps \(left) layers of the motion and the colour \(String(describing: Self.rgba(layer.backgroundColor))) on its cell")
    }

    /// A pane whose clip is its card and has a colour of its own (the user's colour for the docks): at rest that
    /// colour is over what the window shows in the card. The ground in the clip would cover it, so the ground has
    /// 1 layer with that colour over all of it: over the plain ground, and over the tint of a copy.
    @Test(arguments: [false, true])
    func inACardAColourOfThePanesOwnClipShowsOverTheGround(_ picture: Bool) throws {
        let own = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.5).cgColor
        let scene = try Self.closeInStyle(cards: true, picture: picture, own: own)
        defer { scene.harness.window.closeAfterTest() }
        let clip = try #require(scene.host.clipView.layer, "SETUP: the pane's clip has no layer")
        try #require(Self.rgba(clip.backgroundColor) == Self.rgba(own), "SETUP: the clip does not have its own colour in the close's move")
        let ground = try #require(Self.grounds(inCardOf: scene.host).first, "the pane's clip has no ground of the motion in the close's move")
        let layers = ground.sublayers ?? [], over = layers.filter { $0.backgroundColor != nil }
        #expect(over.count == (picture ? 2 : 1) && layers.count == over.count,
                "over \(picture ? "a picture" : "a colour") the ground has \(over.count) colour layers in \(layers.count) layers")
        #expect(Self.rgba(over.last?.backgroundColor) == Self.rgba(own),
                "the top layer of the ground has \(String(describing: Self.rgba(over.last?.backgroundColor))); the clip's own colour is \(String(describing: Self.rgba(own)))")
        let covers = over.last.map { $0.frame == ground.bounds } ?? false
        #expect(covers, "the clip's own colour covers \(String(describing: over.last?.frame)) of the ground's \(ground.bounds)")
    }

    /// `node` with `pane` out: the other half of that pane's split has the split's place. Nil: `node` is that pane.
    static func without(_ pane: PaneID, in node: SplitNode) -> SplitNode? {
        switch node {
        case .leaf(let id):
            return id == pane ? nil : node
        case let .split(id, axis, ratio, a, b):
            guard let first = without(pane, in: a) else { return b }
            guard let second = without(pane, in: b) else { return a }
            return .split(id, axis: axis, ratio: ratio, a: first, b: second)
        }
    }

    /// A pane that moved in a motion with no copy of the window's picture gets none at a later act of that motion:
    /// a copy is at its place only with each move of its pane from the start. The first close comes while the
    /// window's tint is in a change: the window shows no still picture, and no pane gets a copy. The change ends.
    /// The second close moves 2 other panes for the first time: each has 1 copy. The third close moves the pane of
    /// the first close again: it has no copy, and the 2 others keep theirs. With no card for each pane, where a
    /// copy is on the pane's cell, and with a card, where it is in the pane's clip.
    @Test(arguments: [false, true])
    func aPaneThatMovedWithNoCopyGetsNoneAtALaterActOfTheMotion(_ cards: Bool) throws {
        var tree = Self.tree(6)
        let harness = Commit.Harness(Commit.screen(tree), focused: "p", holds: false) { model in
            guard cards else { return }
            model.followsDesignMetrics = false
            model.baseStyle.panePadding = 6
            model.baseStyle.paneCornerRadius = 10
            model.baseStyle.floatingPanes = true
            model.baseStyle.dividerThickness = 0
        }
        defer { harness.window.closeAfterTest() }
        func copies(_ host: PaneHostView) -> Int {
            cards ? Self.grounds(inCardOf: host).filter { $0.name == Self.pictureCopy }.count : Self.pictures(on: host).count
        }
        let backdrop = Self.picture(under: harness, gap: "changing")
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        func close(_ pane: PaneID) throws {
            tree = try #require(Self.without(pane, in: tree), "SETUP: the tree is the pane \(pane) alone")
            harness.model.apply(screens: Commit.screen(tree))
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
            try #require(Self.inFlight(screen), "SETUP: no pane moves at the close of \(pane)")
        }
        let hosts = harness.root.context.hosts
        let first = try #require(hosts["paab"], "SETUP: the pane beside the first pane has no host")
        let upper = try #require(hosts["pb"], "SETUP: the pane `pb` has no host")
        let beside = try #require(hosts["pbab"], "SETUP: the pane `pbab` has no host")
        let others = [upper, beside]
        try #require(first.wholeCard == cards, "SETUP: the clip of the first close's pane is its card: \(first.wholeCard), not \(cards)")
        try close("p")
        try #require(Self.moves(first) && !others.contains { Self.moves($0) }, "SETUP: the first close does not move the pane beside it alone")
        #expect(copies(first) == 0, "the first close's pane has \(copies(first)) copies while the window's tint is in a change")
        backdrop.shownTintLayer?.removeAnimation(forKey: "test.blend")
        var still = false
        if case .still = backdrop.stillPicture { still = true }
        try #require(still, "SETUP: the backdrop reads as no still picture after the change of its tint ended")
        try close("pbb")
        try #require(others.allSatisfy { Self.moves($0) }, "SETUP: the second close does not move the 2 panes over the pane that left")
        let second = others.map { copies($0) }
        #expect(second == [1, 1], "the 2 panes that move first at the second close have \(second) copies of the window's picture")
        try close("pab")
        let acts = Set((first.layer?.animationKeys() ?? []).compactMap { Self.act(of: $0) })
        try #require(acts.count == 2, "SETUP: the first close's pane has the moves of \(acts.count) acts, not of the first and the third close")
        let third = others.map { copies($0) }
        #expect(copies(first) == 0, "the pane that moved with no copy has \(copies(first)) copies at its second move")
        #expect(third == [1, 1], "after the third close the 2 panes of the second close have \(third) copies of the window's picture")
    }
}
