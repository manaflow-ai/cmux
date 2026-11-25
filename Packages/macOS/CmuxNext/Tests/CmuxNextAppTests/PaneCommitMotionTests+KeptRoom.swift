import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a pane that a close keeps under the others when panes come over it from 2 sides, and when
/// a second close key comes in the first one's move.
///
/// One close key can give the closed pane's room to panes on 2 opposite sides of it: a close of a middle row of a
/// column (the rows that stay keep their heights), and a close of a middle pane with even split sizes. A hold of the
/// close key gives a second close while the panes of the first still move: a pane that comes over a kept pane then
/// has 2 moves on it, with 2 timings. In each frame the kept pane shows nowhere under a pane over it, and whole in
/// the room that those panes have not yet: they grow over the pane that left, not over the window's ground.
extension PaneCommitMotionTests {
    /// A layout in which the close key gives the closed pane's room to panes on 2 opposite sides of it, or to a pane
    /// that the next close key takes out, and the pane that the first key closes.
    struct Between {
        let screens: [LayoutScreen]
        let closes: PaneID
        let even: Bool
        /// The pane that a second close key must take out for the scene's state; nil: the scene names none.
        var next: PaneID?
    }

    nonisolated static let betweens = [
        "3 rows", "4 rows", "3 side by side", "the last of 3 side by side", "2 side by side above 1", "2 rows beside 1", "2 by 2",
    ]

    /// - `3 rows`: a column of 3 rows, a close of the middle row. The rows that stay keep their heights, so the row
    ///   above grows down and the row below grows up.
    /// - `4 rows`: a column of 4 rows of 4 heights, a close of the second row. The 2 rows below it are smaller than
    ///   it: the row above and both rows below come over it, and the room between them is not in its middle.
    /// - `3 side by side`: 3 panes in a row with even split sizes, a close of the middle pane. The 2 panes that stay
    ///   get a half each.
    /// - `the last of 3 side by side`: 3 panes in a row with even split sizes, a close of the last pane. The pane
    ///   before it grows over it and gets the focus: a second key closes that pane while it still grows, and the
    ///   first pane then grows over it from where it shows, which is not its place in the layout.
    /// - `2 side by side above 1`, `2 rows beside 1`: 3 panes on 2 axes, a close of the first of the 2. The other one
    ///   of the 2 grows over it and gets the focus; a second key closes that one while it still grows, and the third
    ///   pane then grows over both from the other axis.
    /// - `2 by 2`: 4 panes in 2 columns of 2 rows, a close of the first pane, a corner of the screen. The pane that
    ///   grows over it has a pane beside it, and a second key in the move brings a pane over a part of each.
    static func between(_ scene: String) -> Between {
        func three(_ axis: SplitAxis, _ other: SplitAxis) -> Between {
            let two = SplitNode.split(SplitID("new"), axis: axis, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1"))
            return Between(screens: Commit.screen(.split(SplitID("pair"), axis: other, ratio: 0.5, a: two, b: .leaf("p2"))), closes: "p0", even: true, next: "p1")
        }
        func column(_ heights: [Int]) -> [LayoutScreen] {
            let rows = heights.enumerated().map { LayoutRow(id: RowID("r\($0.offset)"), height: $0.element, root: .leaf(PaneID("p\($0.offset)"))) }
            var root = rows[0].root, above = Double(rows[0].height)
            for (index, row) in rows.enumerated().dropFirst() {
                root = .split(SplitID("s\(index)"), axis: .vertical, ratio: above / (above + Double(row.height)), a: root, b: row.root)
                above += Double(row.height)
            }
            return [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c", width: 1, root: root, rows: rows)]), zoomed: false)]
        }
        let first = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1"))
        let thirds = Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 2.0 / 3, a: first, b: .leaf("p2")))
        switch scene {
        case "3 rows": return Between(screens: column([300, 300, 300]), closes: "p1", even: false)
        case "4 rows": return Between(screens: column([200, 400, 100, 300]), closes: "p1", even: false)
        case "3 side by side": return Between(screens: thirds, closes: "p1", even: true)
        case "2 side by side above 1": return three(.horizontal, .vertical)
        case "2 rows beside 1": return three(.vertical, .horizontal)
        case "2 by 2": return Between(screens: Commit.screen(Self.tree(4)), closes: "p", even: true)
        default:
            let last = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
            return Between(screens: Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p0"), b: last)), closes: "p2", even: true)
        }
    }

    /// How near a pane over it a kept pane can be out of sight where that pane is not: the largest room between 2
    /// panes of `rest` (the panes at rest) that are side by side or one above the other, and 1 pt. Two panes that go
    /// over a kept pane from one side have that room between them, where a divider's line is.
    static func margin(among rest: [PaneHostView]) -> CGFloat {
        var gap: CGFloat = 0
        for a in rest {
            // The nearest pane after `a` on each axis, of the panes that share a part of its other axis.
            let beside = rest.filter { $0.frame.minX >= a.frame.maxX && $0.frame.minY < a.frame.maxY && $0.frame.maxY > a.frame.minY }.map { $0.frame.minX - a.frame.maxX }.min()
            let below = rest.filter { $0.frame.minY >= a.frame.maxY && $0.frame.minX < a.frame.maxX && $0.frame.maxX > a.frame.minX }.map { $0.frame.minY - a.frame.maxY }.min()
            gap = max(gap, beside ?? 0, below ?? 0)
        }
        return gap + 1
    }

    /// What the screen shows of the panes of `left` (the panes that left, in the order of their closes) when the moves
    /// of each act are at `part(act)` of their way. Each one shows in less than 1 pt2 of the rect of each pane over
    /// it, as that pane shows: each pane of the layout, and each pane that left after it. It shows through none of
    /// them. And it shows whole in its place farther than `margin` from each of them (``margin(among:)``).
    static func expectKept(_ left: [PaneHostView], on screen: ScreenContentView, margin: CGFloat, _ when: String, at part: (Int) -> CGFloat) {
        let layout = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden && $0.alphaValue > 0 && !$0.isLeaving }
        for (index, host) in left.enumerated() {
            let under = kept(host, on: screen, over: layout + left.dropFirst(index + 1), at: part)
            let over = under.grounds + under.bare
            for rect in over {
                let area = under.area(in: rect)
                #expect(area < 1, "\(when) the pane \(host.pane) that left shows in \(area) pt2 of the rect \(rect) of a pane over it")
            }
            #expect(under.through < 1, "\(when) the screen shows \(under.through) pt2 of the pane \(host.pane) that left through a pane over it")
            let room = uncovered(over.map { $0.insetBy(dx: -margin, dy: -margin) }, in: under.shows), shown = under.area(in: under.shows)
            #expect(shown >= room - 1, "\(when) the pane \(host.pane) that left shows in \(shown) pt2; \(room) pt2 of its place \(under.shows) are away from each pane over it")
        }
    }

    /// Whether the screen's order has each pane of `left` (the panes that left, in the order of their closes) under
    /// each pane of the layout and under each pane that left after it: what ``expectKept(_:on:margin:_:at:)`` reads
    /// as the panes over a pane is what the screen draws over it.
    static func keepsInOrder(_ left: [PaneHostView], on screen: ScreenContentView) -> Bool {
        let lowest = stack(on: screen).prefix(left.count)
        return lowest.count == left.count && zip(lowest, left).allSatisfy { $0 === $1 }
    }

    /// A hold of the close key (`LayoutModel.showPaneClose`, 2 times): the second key closes the pane that has the
    /// focus after the first, while the panes of the first close still move. The 2 closes have 2 timings, so the
    /// frames are read with the first close's moves farther on their way than the second's. In each of them each of
    /// the 2 panes that left shows nowhere under a pane over it, as that pane shows with both moves on it, and whole
    /// in the room that those panes have not yet. The pane that the second key took out stays over the first one.
    @Test(arguments: betweens)
    func afterASecondCloseKeyEachPaneThatLeftShowsWholeInTheRoomThatNoPaneHas(_ scene: String) throws {
        let between = Self.between(scene)
        let harness = Commit.Harness(between.screens, focused: between.closes, holds: false) { $0.splitSizingOverride = between.even ? .even : .halve }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let first = try #require(rest[between.closes], "SETUP: the pane that closes does not show at rest")
        let margin = Self.margin(among: Array(rest.values))

        _ = try #require(harness.model.showPaneClose(between.closes), "SETUP: the model does not show the close of \(between.closes)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let next = try #require(harness.model.focusedPane, "SETUP: no pane has the focus after the first close")
        let second = try #require(rest[next], "SETUP: the pane \(next) that has the focus after the first close did not show at rest")
        try #require(between.next == nil || between.next == next, "SETUP: the focus after the first close is on \(next), and the scene's second close is of \(between.next ?? next)")
        try #require(second !== first, "SETUP: the pane that closed keeps the focus")
        _ = try #require(harness.model.showPaneClose(next), "SETUP: the model does not show the close of \(next) in the first close's move")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(first.isLeaving && !first.isHidden && second.isLeaving && !second.isHidden, "SETUP: the move does not keep the 2 panes that left")
        let acts = Self.acts(on: screen)
        try #require(acts.count == 2, "SETUP: the panes have the moves of \(acts.count) acts, not of the 2 closes: \(acts)")

        for (early, late) in [(0.5, 0), (0.75, 0.25), (0.9, 0.5), (1, 0.75), (1, 1)] as [(CGFloat, CGFloat)] {
            Self.expectKept([first, second], on: screen, margin: margin, "with the first close at \(early) and the second at \(late)") { $0 == acts[1] ? late : early }
        }
        #expect(Self.keepsInOrder([first, second], on: screen), "the 2 panes that left are not under each pane of the layout, the first under the second")
    }

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

    /// The frame of `move`'s layer when each of its animations is at `part` of its way (0: the start, 1: the end). The
    /// math is on each rect's own origin and size: the moves of one act alone can give a size below 0, and `minX` and
    /// `width` of such a rect give the rect's standard form, not its numbers.
    static func ownRect(of move: Move, at part: CGFloat) -> CGRect {
        let start = move.start, end = move.end
        return CGRect(x: start.origin.x + (end.origin.x - start.origin.x) * part, y: start.origin.y + (end.origin.y - start.origin.y) * part,
                      width: start.size.width + (end.size.width - start.size.width) * part,
                      height: start.size.height + (end.size.height - start.size.height) * part)
    }

    /// Where `layer` shows, in its superlayer, when the moves of each act on it are at `part(act)` of their way
    /// (0: the start, 1: the end). Two acts in one move have two timings: they are at two parts in one frame. Each
    /// act's moves add to the layer's own origin and size: one act alone can give a size below 0, the sum is the rect.
    static func rect(of layer: CALayer, at part: (Int) -> CGFloat) -> CGRect {
        let keys = layer.animationKeys() ?? []
        let end = move(of: layer, only: []).end
        var origin = end.origin, size = end.size
        for number in Set(keys.compactMap({ Self.act(of: $0) })) {
            let one = ownRect(of: move(of: layer, only: Set(keys.filter { Self.act(of: $0) == number })), at: part(number))
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
}
