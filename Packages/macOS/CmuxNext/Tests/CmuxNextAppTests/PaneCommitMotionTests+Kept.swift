import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the panes that a move keeps on the screen under the others (a pane that a close took out,
/// a pane that a zoom covers): where they show, and what the rings of the other panes read of them.
///
/// - A kept pane shows only where no pane over it shows. A pane's tab strip has no ground of its own, so a kept pane
///   that shows under the pane that goes over it shows through that pane's tabs. A mask on the kept pane's clip
///   leaves of it what no pane has yet, and each edge of that goes with the edge of a pane as the pane shows: the
///   same start, the same end, the same timing, also when 2 acts move the pane (`PaneCommitMotionTests+KeptRoom`).
/// - A pane's ring leaves out the rects of the panes in front of it (`ScreenContentView.panesAbove()`). Between the
///   turn of a change and the pass that shows it the screen shows the layout before the change, so the rings read the
///   panes as they show: a pane that left still covers, a pane that the move keeps under covers nothing.
extension PaneCommitMotionTests {
    // MARK: What the mask on a kept pane's clip leaves of it

    /// The act whose timing the animation with `key` has. A pane's own move has its act's number
    /// (`pane.commit.N.position`); a move that a layer of a mask got from a pane's move has the number of that
    /// move's act (`.kept.N`).
    static func act(of key: String) -> Int? {
        let words = key.components(separatedBy: ".")
        guard words.count > 2, words[0] == "pane", words[1] == "commit" else { return nil }
        if let kept = words.firstIndex(of: "kept"), kept + 1 < words.count { return Int(words[kept + 1]) }
        return Int(words[2])
    }

    /// The acts whose moves are on the pane hosts of `screen` now, in their order.
    static func acts(on screen: ScreenContentView) -> [Int] {
        let keys = screen.subviews.compactMap { ($0 as? PaneHostView)?.layer }.flatMap { $0.animationKeys() ?? [] }
        return Set(keys.compactMap { Self.act(of: $0) }).sorted()
    }

    /// Where `layer` shows, in its superlayer, when the moves of each act on it are at `part(act)` of their way
    /// (0: the start, 1: the end). Two acts in one move have two timings: they are at two parts in one frame.
    static func rect(of layer: CALayer, at part: (Int) -> CGFloat) -> CGRect {
        let keys = layer.animationKeys() ?? []
        let end = move(of: layer, only: []).end
        var rect = end
        for number in Set(keys.compactMap({ Self.act(of: $0) })) {
            let one = move(of: layer, only: Set(keys.filter { Self.act(of: $0) == number })).rect(at: part(number))
            rect = CGRect(x: rect.minX + one.minX - end.minX, y: rect.minY + one.minY - end.minY,
                          width: rect.width + one.width - end.width, height: rect.height + one.height - end.height)
        }
        return rect
    }

    /// The origin of the own coordinates of `layer` at `part`: its `bounds.origin`, and each animation that adds to it.
    /// A layer that moves, and whose origin moves as far, keeps the layers in it where they are.
    static func origin(of layer: CALayer, at part: (Int) -> CGFloat) -> CGPoint {
        var origin = layer.bounds.origin
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, animation.keyPath == "bounds.origin", animation.isAdditive,
                  let from = (animation.fromValue as? NSValue)?.pointValue, let number = Self.act(of: key) else { continue }
            let to = (animation.toValue as? NSValue)?.pointValue ?? .zero, way = part(number)
            origin.x += from.x + (to.x - from.x) * way
            origin.y += from.y + (to.y - from.y) * way
        }
        return origin
    }

    /// The rects in which `layer` shows with the layers in it, in its superlayer's coordinates, at `part`: a layer
    /// with a colour shows in its rect, and a layer that clips shows the layers in it only inside its rect.
    static func shown(_ layer: CALayer, at part: (Int) -> CGFloat) -> [CGRect] {
        let frame = rect(of: layer, at: part), origin = origin(of: layer, at: part)
        var rects = layer.backgroundColor == nil ? [] : [frame]
        for inner in (layer.sublayers ?? []).flatMap({ shown($0, at: part) }) {
            let moved = inner.offsetBy(dx: frame.minX - origin.x, dy: frame.minY - origin.y)
            let rect = layer.masksToBounds ? moved.intersection(frame) : moved
            if !rect.isNull, rect.width > 0, rect.height > 0 { rects.append(rect) }
        }
        return rects
    }

    /// The mask that a move puts on the clip of a pane that it keeps; nil: the clip has none.
    static func keptMask(of host: PaneHostView) -> CALayer? {
        guard let mask = host.clipView.layer?.mask, mask.name == "pane.commit.cut" else { return nil }
        return mask
    }

    /// Each layer in `layer`, at each depth.
    static func layers(in layer: CALayer) -> [CALayer] { (layer.sublayers ?? []).flatMap { [$0] + layers(in: $0) } }

    /// Where a pane that a move keeps shows on its screen at one part of the moves.
    @MainActor struct Kept {
        /// The pane's clip in its layer's rect.
        var shows: CGRect
        /// The rects of `shows` in which the pane shows: the whole, or what the mask on its clip leaves of it. A mask
        /// shows its layer where a layer of the mask shows.
        var parts: [CGRect]

        /// The area of `region` in which the pane shows.
        func area(in region: CGRect) -> CGFloat {
            let part = shows.intersection(region)
            guard !part.isNull, part.width > 0, part.height > 0 else { return 0 }
            return part.width * part.height - PaneCommitMotionTests.uncovered(parts, in: part)
        }
    }

    /// Where `host` shows on `screen` when the moves of each act are at `part(act)` of their way: its clip, in its
    /// layer's rect, as far as the mask on the clip shows it. The clip and its mask go with the layer.
    static func kept(_ host: PaneHostView, on screen: ScreenContentView, at part: (Int) -> CGFloat) -> Kept {
        let rect = host.layer.map { Self.rect(of: $0, at: part) } ?? host.frame
        let dx = rect.minX - host.frame.minX, dy = rect.minY - host.frame.minY
        func onScreen(_ rect: CGRect) -> CGRect { screen.convert(rect, from: host.clipView).offsetBy(dx: dx, dy: dy) }
        let shows = onScreen(host.clipView.bounds).intersection(rect)
        guard let mask = keptMask(of: host) else { return Kept(shows: shows, parts: [shows]) }
        return Kept(shows: shows, parts: shown(mask, at: part).map { onScreen($0).intersection(shows) }.filter { !$0.isNull })
    }

    /// The same, with the moves of each act at one `part`.
    static func kept(_ host: PaneHostView, on screen: ScreenContentView, at part: CGFloat) -> Kept {
        kept(host, on: screen) { _ in part }
    }

    /// A pane that left the layout shows nowhere under the pane that goes over it, and whole in the room that no pane
    /// has yet: at the start, at each quarter and at the end of the move of the pane over it. A zoom of the pane that
    /// is under the other pane of a pair, and a close of the pane that is above the other. The mask goes with the
    /// pane: one timing, and one animation at most on each of its layers. After the motion's end the pane that left
    /// has no mask on its clip: a zoom's pane comes back whole.
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
        let cut = Self.keptMask(of: left).map { Self.layers(in: $0).map { Self.move(of: $0) } } ?? []
        let timings = Set(cut.flatMap { $0.animations.map { Self.timing($0) } })
        let pace: Set<String> = Set(move.animations.prefix(1).map { Self.timing($0) })
        #expect(timings == pace, "the mask's moves are \(timings.sorted()); the move of the pane over it is \(pace.sorted())")
        let count = cut.map(\.animations.count)
        #expect(count.allSatisfy { $0 <= 1 }, "the layers of the mask have \(count) animations after one act")

        _ = Self.toTheEnd(alone.harness, alone.screen)
        #expect(left.clipView.layer?.mask == nil, "after the motion's end the pane that left keeps a mask on its clip")
    }

    /// A hold of the close key: a second close in the first close's move, of the pane that the first close made grow
    /// over the first closed pane. That pane still moves when the move keeps it, so its clip and the mask on it move
    /// too: what its mask leaves of it goes with the pane over it, not with that move. At the start, at each quarter
    /// and at the end of the moves, each of the 2 panes that left shows nowhere under the pane of the layout, the
    /// first nowhere under the second, and each shows whole in the room that no pane has yet. The mask's own move
    /// starts when the first close's move started.
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
        let own = Self.keptMask(of: second).map { Self.move(of: $0).animations } ?? []
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
