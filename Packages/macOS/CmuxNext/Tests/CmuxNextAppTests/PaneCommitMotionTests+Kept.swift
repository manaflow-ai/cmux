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
///   that shows under the pane that goes over it shows through that pane's tabs. What the screen shows of a pane in a
///   frame is read from the layers (``kept(_:on:over:at:)``): the pane's clip, less what a mask on that clip takes
///   away (the move of one pane puts one there, `PaneCommitMotion+Under`), less the rect of each pane over it that has a ground of alpha 1 on its whole cell. Under a pane over it
///   that has no such ground the pane shows through: text over text (`PaneCommitMotionTests+KeptRoom`, `+Sheet`).
/// - A pane's ring leaves out the rects of the panes in front of it (`ScreenContentView.panesAbove()`). Between the
///   turn of a change and the pass that shows it the screen shows the layout before the change, so the rings read the
///   panes as they show: a pane that left still covers, a pane that the move keeps under covers nothing.
extension PaneCommitMotionTests {
    // MARK: What the screen shows of a pane under the others

    /// The act whose timing the animation with `key` has: the first number in the key of a move of this motion
    /// (`pane.commit.N.position`).
    static func act(of key: String) -> Int? {
        let words = key.components(separatedBy: ".")
        guard words.count > 2, words[0] == "pane", words[1] == "commit" else { return nil }
        return words.dropFirst(2).lazy.compactMap { Int($0) }.first
    }

    /// The acts whose moves are on the pane hosts of `screen` now, in their order.
    static func acts(on screen: ScreenContentView) -> [Int] {
        let keys = screen.subviews.compactMap { ($0 as? PaneHostView)?.layer }.flatMap { $0.animationKeys() ?? [] }
        return Set(keys.compactMap { Self.act(of: $0) }).sorted()
    }

    /// Where `layer` shows, in its superlayer, when the moves of each act on it are at `part(act)` of their way
    /// (0: the start, 1: the end). Two acts in one move have two timings: they are at two parts in one frame. Each
    /// act's moves add to the layer's own origin and size: one act alone can give a size below 0, the sum is the rect.
    static func rect(of layer: CALayer, at part: (Int) -> CGFloat) -> CGRect {
        let keys = layer.animationKeys() ?? []
        let end = move(of: layer, only: []).end
        var origin = end.origin, size = end.size
        for number in Set(keys.compactMap({ Self.act(of: $0) })) {
            let one = move(of: layer, only: Set(keys.filter { Self.act(of: $0) == number })).rect(at: part(number))
            origin = CGPoint(x: origin.x + one.origin.x - end.origin.x, y: origin.y + one.origin.y - end.origin.y)
            size = CGSize(width: size.width + one.size.width - end.size.width, height: size.height + one.size.height - end.size.height)
        }
        return CGRect(origin: origin, size: size)
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

    /// Each layer in `layer`, at each depth.
    static func layers(in layer: CALayer) -> [CALayer] { (layer.sublayers ?? []).flatMap { [$0] + layers(in: $0) } }

    /// The area of `bounds` whose points `counts` takes. `rects`: each rect that `counts` reads; all the points
    /// between 2 edges of them count alike.
    static func area(of bounds: CGRect, cutBy rects: [CGRect], where counts: (CGPoint) -> Bool) -> CGFloat {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return 0 }
        let inside = rects.map { $0.intersection(bounds) }.filter { !$0.isNull }
        let columns = Set([bounds.minX, bounds.maxX] + inside.flatMap { [$0.minX, $0.maxX] }).sorted()
        let rows = Set([bounds.minY, bounds.maxY] + inside.flatMap { [$0.minY, $0.maxY] }).sorted()
        var area: CGFloat = 0
        for (left, right) in zip(columns, columns.dropFirst()) {
            for (top, bottom) in zip(rows, rows.dropFirst()) where counts(CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)) {
                area += (right - left) * (bottom - top)
            }
        }
        return area
    }

    /// What the screen shows of one pane on its screen at one part of the moves.
    @MainActor struct Kept {
        /// The pane's clip in its layer's rect, in the screen's coordinates: where the pane's content is.
        var shows: CGRect
        /// The rects of `shows` that a mask on the clip leaves of the pane: the whole of it, with no mask. A mask
        /// shows its layer where a layer of the mask shows.
        var parts: [CGRect]
        /// The rects of the panes over it that have a ground of alpha 1 on their whole cell: none of it shows there.
        var grounds: [CGRect] = []
        /// The rects of the panes over it that have no such ground: it shows through what they do not paint.
        var bare: [CGRect] = []

        /// The area of `region` in which the screen shows the pane.
        func area(in region: CGRect) -> CGFloat {
            PaneCommitMotionTests.area(of: shows.intersection(region), cutBy: parts + grounds) { point in
                parts.contains { $0.contains(point) } && !grounds.contains { $0.contains(point) }
            }
        }

        /// The area in which the screen shows the pane through a pane over it: text over text.
        var through: CGFloat {
            PaneCommitMotionTests.area(of: shows, cutBy: parts + grounds + bare) { point in
                parts.contains { $0.contains(point) } && bare.contains { $0.contains(point) } && !grounds.contains { $0.contains(point) }
            }
        }
    }

    /// The pane hosts that show on `screen`, from the lowest: by their layers' `zPosition`, then by the order of the
    /// screen's views.
    static func stack(on screen: ScreenContentView) -> [PaneHostView] {
        let shown = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden && $0.alphaValue > 0 }
        return shown.enumerated().sorted { one, other in
            let low = one.element.layer?.zPosition ?? 0, high = other.element.layer?.zPosition ?? 0
            return low == high ? one.offset < other.offset : low < high
        }.map(\.element)
    }

    /// What the screen shows of `host` on `screen` when the moves of each act are at `part(act)` of their way, from the
    /// layers: its clip in its layer's rect, as far as a mask on the clip shows it, and the rect of each pane host
    /// over it, as that one shows, with or with no ground on its layer. `over`: the hosts over it; nil: each host
    /// that is above it in the screen's order (``stack(on:)``). The clip and its mask go with the layer.
    static func kept(_ host: PaneHostView, on screen: ScreenContentView, over: [PaneHostView]? = nil, at part: (Int) -> CGFloat) -> Kept {
        let rect = host.layer.map { Self.rect(of: $0, at: part) } ?? host.frame
        let dx = rect.minX - host.frame.minX, dy = rect.minY - host.frame.minY
        func onScreen(_ rect: CGRect) -> CGRect { screen.convert(rect, from: host.clipView).offsetBy(dx: dx, dy: dy) }
        let shows = onScreen(host.clipView.bounds).intersection(rect)
        var kept = Kept(shows: shows, parts: [shows])
        if let mask = host.clipView.layer?.mask {
            kept.parts = shown(mask, at: part).map { onScreen($0).intersection(shows) }.filter { !$0.isNull }
        }
        let order = stack(on: screen)
        let above = over ?? order.firstIndex { $0 === host }.map { Array(order.dropFirst($0 + 1)) } ?? []
        for layer in above.compactMap(\.layer) {
            let cell = Self.rect(of: layer, at: part)
            if (layer.backgroundColor?.alpha ?? 0) >= 1 { kept.grounds.append(cell) } else { kept.bare.append(cell) }
        }
        return kept
    }

    /// The same, with the moves of each act at one `part`.
    static func kept(_ host: PaneHostView, on screen: ScreenContentView, over: [PaneHostView]? = nil, at part: CGFloat) -> Kept {
        kept(host, on: screen, over: over) { _ in part }
    }

    /// A pane that left the layout shows nowhere under the pane that goes over it, also not through that pane's tab
    /// row, and whole in the room that no pane has yet: at the start, at each quarter and at the end of the move of
    /// the pane over it. A zoom of the pane that is under the other pane of a pair, and a close of the pane that is
    /// above the other. After the motion's end the pane that left has no mask on its clip: a zoom's pane comes back
    /// whole.
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
            #expect(under.through < 1, "at \(part) of the \(act)'s move the screen shows \(under.through) pt2 of the pane that left through a pane over it")
            let elsewhere = under.area(in: under.shows) - shown, room = Self.area(under.shows) - Self.area(under.shows.intersection(over))
            #expect(elsewhere >= room - 1, "at \(part) of the \(act)'s move the pane that left shows in \(elsewhere) pt2 of the \(room) pt2 of its place that no pane has yet")
        }

        _ = Self.toTheEnd(alone.harness, alone.screen)
        #expect(left.clipView.layer?.mask == nil, "after the motion's end the pane that left keeps a mask on its clip")
    }

    /// A hold of the close key: a second close in the first close's move, of the pane that the first close made grow
    /// over the first closed pane. That pane still moves when the move keeps it, and it stays over the first one. At
    /// the start, at each quarter and at the end of the moves, each of the 2 panes that left shows nowhere under the
    /// pane of the layout, the first nowhere under the second, and each shows whole in the room that no pane has yet.
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

        harness.model.apply(screens: Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 0.5, a: .leaf(Commit.added), b: .leaf(Commit.right))))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
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
            #expect(a.through < 1 && b.through < 1, "at \(part) the screen shows \(a.through) pt2 of the first pane that left and \(b.through) pt2 of the second through a pane over it")
        }
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

    /// A second pass while a move keeps panes under the others (a pan, a second change) cuts nothing from the pane
    /// that takes the room, and ends no move. A zoom beside a column (`docked`, `overlay`), and the zoom and the
    /// close of a pair.
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
