import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the panes that a move keeps on the screen under the others (a pane that a close took out,
/// a pane that a zoom covers): where they show, and what the rings of the other panes read of them.
///
/// - A kept pane shows only where no pane of the layout shows. A pane's tab strip has no ground of its own, so a kept
///   pane that shows under the pane that goes over it shows through that pane's tabs. A mask on the kept pane's clip
///   takes out one hole, the box of the panes over it, and each edge of that hole goes with its pane: the same
///   start, the same end, the same timing, also after a second act in the move.
/// - A pane's ring leaves out the rects of the panes in front of it (`ScreenContentView.panesAbove()`). Between the
///   turn of a change and the pass that shows it the screen shows the layout before the change, so the rings read the
///   panes as they show: a pane that left still covers, a pane that the move keeps under covers nothing.
extension PaneCommitMotionTests {
    // MARK: What the mask on a kept pane's clip cuts

    /// The cut on the clip of a pane that a move keeps: a mask of 4 bands around one hole, in the order before the
    /// hole in x, after it in x, before it in y, after it in y. A mask shows its layer where a band is, so the pane
    /// shows nowhere in the hole. Each band has the moves of its edge at the hole; the mask's own layer has a move
    /// when its pane still moves.
    struct KeptCut {
        /// The move of the mask's layer in the clip, and the origin of that layer's own coordinates.
        var whole: Move
        var origin: CGPoint
        /// The moves of the 4 bands, in the mask's coordinates, and the timings of their animations.
        var bands: [Move]
        var timings: Set<String>

        /// The hole, in the clip's coordinates, when each move is at `part` of its way (0: the start, 1: the end).
        func hole(at part: CGFloat) -> CGRect {
            let frame = whole.rect(at: part), rects = bands.map { $0.rect(at: part) }
            let x = rects[0].maxX, y = rects[2].maxY
            return CGRect(x: x + frame.minX - origin.x, y: y + frame.minY - origin.y, width: max(0, rects[1].minX - x), height: max(0, rects[3].minY - y))
        }
    }

    /// The cut on the clip of `host`; nil: its clip has no mask of that kind.
    static func keptCut(of host: PaneHostView) -> KeptCut? {
        guard let mask = host.clipView.layer?.mask, mask.name == "pane.commit.cut", let bands = mask.sublayers, bands.count == 4 else { return nil }
        let moves = bands.map { move(of: $0) }
        return KeptCut(whole: move(of: mask), origin: mask.bounds.origin, bands: moves, timings: Set(moves.flatMap { $0.animations.map { timing($0) } }))
    }

    /// Where a pane that a move keeps shows on its screen at one part of the moves, and the hole of its cut there.
    struct Kept {
        var shows: CGRect
        var hole: CGRect?

        /// The area of `region` in which the pane shows.
        func area(in region: CGRect) -> CGFloat {
            let part = shows.intersection(region)
            guard !part.isNull else { return 0 }
            let cut = hole.map { part.intersection($0) } ?? .null
            return part.width * part.height - (cut.isNull ? 0 : cut.width * cut.height)
        }
    }

    /// Where `host` shows on `screen` when each move is at `part` of its way: its clip, in its layer's rect. The clip
    /// and its mask go with the layer.
    static func kept(_ host: PaneHostView, on screen: ScreenContentView, at part: CGFloat) -> Kept {
        let rect = host.layer.map { move(of: $0).rect(at: part) } ?? host.frame
        let dx = rect.minX - host.frame.minX, dy = rect.minY - host.frame.minY
        let clip = screen.convert(host.clipView.bounds, from: host.clipView).offsetBy(dx: dx, dy: dy)
        let hole = keptCut(of: host).map { screen.convert($0.hole(at: part), from: host.clipView).offsetBy(dx: dx, dy: dy) }
        return Kept(shows: clip.intersection(rect), hole: hole)
    }

    /// A pane that left the layout shows nowhere under the pane that goes over it, and whole in the room that no pane
    /// has yet: at the start, at each quarter and at the end of the move of the pane over it. A zoom of the pane that
    /// is under the other pane of a pair, and a close of the pane that is above the other. The cut goes with the pane:
    /// one timing, and one animation at most for each edge of the hole. After the motion's end the pane that left has
    /// no mask on its clip: a zoom's pane comes back whole.
    @Test(arguments: [true, false])
    func aPaneThatLeftShowsNowhereUnderThePaneOverIt(zoomed: Bool) throws {
        let alone = try Self.alone(zoomed: zoomed)
        defer { alone.harness.window.closeAfterTest() }
        let act = zoomed ? "zoom" : "close"
        let left = try #require(alone.screen.subviews.compactMap { $0 as? PaneHostView }.first { $0 !== alone.host && !$0.isHidden },
                                "SETUP: the pane that left does not show in the \(act)'s move")
        let move = try #require(alone.host.layer.map { Self.move(of: $0) }, "SETUP: the pane that stays has no layer")
        try #require(Self.area(Self.kept(left, on: alone.screen, at: 1).shows) > 1, "SETUP: the clip of the pane that left has no area")
        for part in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let over = move.rect(at: part), under = Self.kept(left, on: alone.screen, at: part)
            let shown = under.area(in: over)
            #expect(shown < 1, "at \(part) of the \(act)'s move the pane that left shows in \(shown) pt2 of the rect \(over) of the pane over it")
            let elsewhere = under.area(in: under.shows) - shown, room = Self.area(under.shows) - Self.area(under.shows.intersection(over))
            #expect(elsewhere >= room - 1, "at \(part) of the \(act)'s move the pane that left shows in \(elsewhere) pt2 of the \(room) pt2 of its place that no pane has yet")
        }
        let cut = Self.keptCut(of: left)
        let pace: Set<String> = Set(move.animations.prefix(1).map { Self.timing($0) })
        #expect(cut?.timings == pace, "the cut's moves are \(cut?.timings.sorted() ?? []); the move of the pane over it is \(pace.sorted())")
        let count = cut?.bands.map(\.animations.count) ?? []
        #expect(count.allSatisfy { $0 <= 1 }, "the 4 edges of the cut's hole have \(count) animations after one act")

        _ = Self.toTheEnd(alone.harness, alone.screen)
        #expect(left.clipView.layer?.mask == nil, "after the motion's end the pane that left keeps a mask on its clip")
    }

    /// A hold of the close key: a second close in the first close's move, of the pane that the first close made grow
    /// over the first closed pane. That pane still moves when the move keeps it, so its clip and the mask on it move
    /// too: the hole of its cut goes with the pane over it, not with that move. At the start, at each quarter and at
    /// the end of the moves, each of the 2 panes that left shows nowhere under the pane of the layout, the first
    /// nowhere under the second, and each shows whole in the room that no pane has yet. The mask's own move starts
    /// when the first close's move started.
    @Test func afterASecondCloseInTheMoveEachPaneThatLeftShowsNowhereUnderAPaneOverIt() throws {
        let harness = Commit.Harness(Commit.pairSplit(.horizontal), focused: Commit.right, holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let first = try #require(rest[Commit.left], "SETUP: the first pane does not show at rest")
        let second = try #require(rest[Commit.added], "SETUP: the second pane does not show at rest")
        let last = try #require(rest[Commit.right], "SETUP: the last pane does not show at rest")

        let before = CACurrentMediaTime()
        harness.model.apply(screens: Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.added), b: .leaf(Commit.right))))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let after = CACurrentMediaTime()
        harness.model.apply(screens: Commit.screen(.leaf(Commit.right)))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(first.isLeaving && !first.isHidden && second.isLeaving && !second.isHidden, "SETUP: the move does not keep the 2 panes that left")
        let grows = try #require(second.layer.map { Self.move(of: $0) }, "SETUP: the second pane has no layer")
        try #require(grows.start.minX > grows.end.minX + 1, "SETUP: the second pane does not still move when the second close keeps it: \(grows.start) to \(grows.end)")
        let move = try #require(last.layer.map { Self.move(of: $0) }, "SETUP: the last pane has no layer")
        try #require(move.moves, "SETUP: the last pane does not move at the second close")

        for part in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let over = move.rect(at: part), middle = grows.rect(at: part)
            let a = Self.kept(first, on: screen, at: part), b = Self.kept(second, on: screen, at: part)
            #expect(b.area(in: over) < 1, "at \(part) the second pane that left shows in \(b.area(in: over)) pt2 of the rect \(over) of the pane over it")
            #expect(a.area(in: over) < 1, "at \(part) the first pane that left shows in \(a.area(in: over)) pt2 of the rect \(over) of the pane of the layout")
            #expect(a.area(in: middle) < 1, "at \(part) the first pane that left shows in \(a.area(in: middle)) pt2 of the rect \(middle) of the second")
            let free = b.area(in: b.shows) - b.area(in: over), room = Self.area(b.shows) - Self.area(b.shows.intersection(over))
            #expect(free >= room - 1, "at \(part) the second pane that left shows in \(free) pt2 of the \(room) pt2 of its place that no pane has yet")
            let front = over.union(middle)
            let open = a.area(in: a.shows) - a.area(in: front), most = Self.area(a.shows) - Self.area(a.shows.intersection(front))
            #expect(open >= most - 1, "at \(part) the first pane that left shows in \(open) pt2 of the \(most) pt2 of its place that no pane has yet")
        }
        let own = Self.keptCut(of: second)?.whole.animations ?? []
        let began = own.first?.beginTime ?? 0
        #expect(own.count == 1 && began >= before && began <= after,
                "the mask of the second pane that left has \(own.count) moves of its own, from \(began); the first close's move began between \(before) and \(after)")
    }

    // MARK: What a ring reads between a change's turn and its pass

    /// The rects that the ring of `host` leaves out, as its last sync placed it; nil: no sync placed it.
    static func ringCovers(of host: PaneHostView) -> [CGRect]? { host.overlaySyncKey?.covers }

    /// A close of the pane of a docked column that is over a part of a strip pane. In the close's turn, before the frame
    /// that shows it, the screen shows the layout before the close: the ring of the strip pane still leaves out the
    /// rect of the column's pane, which left the layout and still shows in front. From the frame that shows the close
    /// it leaves out no rect.
    @Test func inAClosesTurnTheRingStillLeavesOutThePaneInFront() throws {
        let harness = Commit.Harness(Self.dockStrip(.docked), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let host = try #require(rest["p2"], "SETUP: the pane under the column does not show at rest")
        let place = try #require(rest["chat"]?.frame, "SETUP: the column's pane does not show at rest")
        func leavesOut() -> Bool { (Self.ringCovers(of: host) ?? []).contains { Commit.near($0, place) } }
        try #require(leavesOut(), "SETUP: at rest the ring leaves out \(String(describing: Self.ringCovers(of: host))), not the column's pane at \(place)")

        let strip = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")), LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2"))])
        harness.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: strip, zoomed: false)])
        harness.root.syncWithModel()
        try #require(screen.frameInput.changeIsUnshown, "SETUP: the close showed in its own turn")
        #expect(leavesOut(), "in the close's turn the ring leaves out \(String(describing: Self.ringCovers(of: host))): the column's pane still shows in front at \(place)")
        _ = harness.root.advanceFrame(Self.dt)
        #expect(Self.ringCovers(of: host)?.isEmpty == true, "from the frame that shows the close the ring leaves out \(String(describing: Self.ringCovers(of: host)))")
    }

    /// An unzoom in the zoom's move. In the unzoom's turn the screen still shows the zoomed pane over the panes that
    /// the move keeps under it. The unzoom took those panes back into the layout, and the ring of the zoomed pane
    /// still leaves out no rect.
    @Test func inTheTurnOfAnUnzoomInTheZoomsMoveTheRingLeavesOutNoPane() throws {
        let alone = try Self.alone(zoomed: true)
        defer { alone.harness.window.closeAfterTest() }
        #expect(Self.ringCovers(of: alone.host)?.isEmpty == true, "in the zoom's move the ring of the zoomed pane leaves out \(String(describing: Self.ringCovers(of: alone.host)))")
        alone.harness.model.apply(screens: Commit.pair)
        alone.harness.root.syncWithModel()
        try #require(alone.screen.frameInput.changeIsUnshown, "SETUP: the unzoom showed in its own turn")
        #expect(Self.ringCovers(of: alone.host)?.isEmpty == true,
                "in the unzoom's turn the ring of the zoomed pane leaves out \(String(describing: Self.ringCovers(of: alone.host))): the pane that comes back still shows under it")
    }

    /// A second change in a close's move, in its own turn: the pane that the close took out still shows under the
    /// pane that took its room, and that pane's ring still leaves out no rect.
    @Test func inAClosesMoveAChangeThatWaitsLeavesTheRingAsItIs() throws {
        let alone = try Self.alone(zoomed: false)
        defer { alone.harness.window.closeAfterTest() }
        #expect(Self.ringCovers(of: alone.host)?.isEmpty == true, "in the close's move the ring of the pane that took the room leaves out \(String(describing: Self.ringCovers(of: alone.host)))")
        let halves = SplitNode.split(SplitID("again"), axis: .horizontal, ratio: 0.5, a: .leaf(alone.host.pane), b: .leaf(Commit.added))
        alone.harness.model.apply(screens: Commit.screen(halves))
        alone.harness.root.syncWithModel()
        try #require(alone.screen.frameInput.changeIsUnshown, "SETUP: the second change showed in its own turn")
        #expect(Self.ringCovers(of: alone.host)?.isEmpty == true,
                "in the turn of a change in the close's move the ring leaves out \(String(describing: Self.ringCovers(of: alone.host))): the closed pane still shows under the pane")
    }

    // MARK: A second pass in the move

    nonisolated static let passes = DockMode.allCases.map(\.rawValue) + ["zoom", "close"]

    /// A pass that makes the masks again while a move keeps panes under the others (a pan, a second change) cuts
    /// nothing from the pane that takes the room, and ends no move. A zoom beside a column (`docked`, `overlay`), and
    /// the zoom and the close of a pair.
    @Test(arguments: passes)
    func aSecondPassInTheMoveCutsNothing(_ scene: String) throws {
        let dock = DockMode(rawValue: scene)
        let alone: Alone? = try dock == nil ? Self.alone(zoomed: scene == "zoom") : nil
        let harness = alone?.harness ?? Commit.Harness(Self.dockStrip(dock ?? .docked), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        if let dock {
            Self.movePanes(harness)
            Commit.rest(harness)
            harness.model.apply(screens: Self.dockStrip(dock, zoomedOn: "p1"))
            harness.root.syncWithModel()
            _ = harness.root.advanceFrame(Self.dt)
        }
        let screen = try #require(harness.screen)
        let host = try #require(alone?.host ?? harness.root.context.hosts["p1"], "SETUP: the pane that takes the room has no host")
        let kept = screen.subviews.compactMap { $0 as? PaneHostView }.filter { $0.isLeaving && !$0.isHidden }
        try #require(Self.inFlight(screen) && !kept.isEmpty, "SETUP: no pane moves, or the move keeps no pane that left (\(kept.count))")

        screen.applyPresentation(force: true)
        #expect(Self.cut(of: host) == nil, "a second pass in the move cuts the pane that takes the room: \(Self.cut(of: host) ?? "")")
        #expect(Self.inFlight(screen) && kept.allSatisfy { !$0.isHidden }, "the second pass ended the move, or hid a pane that the move keeps")
    }
}
