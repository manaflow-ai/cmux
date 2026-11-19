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
    }

    nonisolated static let betweens = ["3 rows", "4 rows", "3 side by side", "the last of 3 side by side"]

    /// - `3 rows`: a column of 3 rows, a close of the middle row. The rows that stay keep their heights, so the row
    ///   above grows down and the row below grows up.
    /// - `4 rows`: a column of 4 rows of 4 heights, a close of the second row. The 2 rows below it are smaller than
    ///   it: the row above and both rows below come over it, and the room between them is not in its middle.
    /// - `3 side by side`: 3 panes in a row with even split sizes, a close of the middle pane. The 2 panes that stay
    ///   get a half each.
    /// - `the last of 3 side by side`: 3 panes in a row with even split sizes, a close of the last pane. The pane
    ///   before it grows over it and gets the focus: a second key closes that pane while it still grows, and the
    ///   first pane then grows over it from where it shows, which is not its place in the layout.
    static func between(_ scene: String) -> Between {
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
        default:
            let last = SplitNode.split(SplitID("new"), axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
            return Between(screens: Commit.screen(.split(SplitID("pair"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p0"), b: last)), closes: "p2", even: true)
        }
    }

    /// The spring and the length of `animation`, with no start time.
    static func pace(_ animation: CABasicAnimation) -> String {
        let spring = (animation as? CASpringAnimation).map { "spring \($0.mass) \($0.stiffness) \($0.damping)" } ?? "no spring"
        return "\(animation.duration) s \(spring)"
    }

    /// What the panes of `left` (the panes that left, in the order of their closes) show when the moves of each act
    /// are at `part(act)` of their way. Each one shows in less than 1 pt2 of the rect of each pane over it, as that
    /// pane shows: each pane of the layout, and each pane that left after it. And it shows whole in its place
    /// farther than `margin` from each of them: `margin` is more than a divider between 2 panes, and much less than
    /// a room that a fault leaves to the window's ground.
    static func expectKept(_ left: [PaneHostView], on screen: ScreenContentView, margin: CGFloat = 12, _ when: String, at part: (Int) -> CGFloat) {
        let layout = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden && $0.alphaValue > 0 && !$0.isLeaving }
        for (index, host) in left.enumerated() {
            let under = kept(host, on: screen, at: part)
            let over = (layout + left.dropFirst(index + 1)).compactMap(\.layer).map { rect(of: $0, at: part) }
            for rect in over {
                let area = under.area(in: rect)
                #expect(area < 1, "\(when) the pane \(host.pane) that left shows in \(area) pt2 of the rect \(rect) of a pane over it")
            }
            let room = uncovered(over.map { $0.insetBy(dx: -margin, dy: -margin) }, in: under.shows), shown = under.area(in: under.shows)
            #expect(shown >= room - 1, "\(when) the pane \(host.pane) that left shows in \(shown) pt2; \(room) pt2 of its place \(under.shows) are away from each pane over it")
        }
    }

    /// One close key (`LayoutModel.showPaneClose`) of a pane whose room goes to panes on 2 opposite sides of it, in a
    /// column and in a row of 3. At the start, at each quarter and at the end of their moves the pane that left
    /// shows nowhere under each of them, and whole in the room between them. The mask goes with them: one timing.
    @Test(arguments: Array(betweens.prefix(3)))
    func aPaneThatLeftBetweenPanesShowsWholeInTheRoomBetweenThem(_ scene: String) throws {
        let between = Self.between(scene)
        let harness = Commit.Harness(between.screens, focused: between.closes, holds: false) { $0.splitSizingOverride = between.even ? .even : .halve }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let closed = try #require(Self.hosts(of: screen)[between.closes], "SETUP: the pane that closes does not show at rest")
        let place = closed.frame

        _ = try #require(harness.model.showPaneClose(between.closes), "SETUP: the model does not show the close of \(between.closes)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(closed.isLeaving && !closed.isHidden, "SETUP: the move does not keep the pane that left")
        let moves = Self.hosts(of: screen).values.filter { $0 !== closed }.compactMap { $0.layer.map { Self.move(of: $0) } }
        let over = moves.filter { $0.moves && Self.area($0.end.intersection(place)) > 1 }
        let rows = over.contains { $0.start.maxY <= place.minY + 1 } && over.contains { $0.start.minY >= place.maxY - 1 }
        let columns = over.contains { $0.start.maxX <= place.minX + 1 } && over.contains { $0.start.minX >= place.maxX - 1 }
        try #require(rows || columns, "SETUP: the panes over the closed pane at \(place) do not come from 2 opposite sides: \(over.map { "\($0.start) to \($0.end)" })")

        for part in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            Self.expectKept([closed], on: screen, "at \(part) of the close's move") { _ in part }
        }
        let pace = Set(over.flatMap { $0.animations.map { Self.timing($0) } })
        let cut = Set((Self.keptMask(of: closed).map { Self.layers(in: $0) } ?? []).flatMap { Self.move(of: $0).animations.map { Self.timing($0) } })
        #expect(pace.count == 1 && cut == pace, "the mask's moves are \(cut.sorted()); the moves of the panes over it are \(pace.sorted())")
    }

    /// A hold of the close key (`LayoutModel.showPaneClose`, 2 times): the second key closes the pane that has the
    /// focus after the first, while the panes of the first close still move. The 2 closes have 2 timings, so the
    /// frames are read with the first close's moves farther on their way than the second's. In each of them each of
    /// the 2 panes that left shows nowhere under a pane over it, as that pane shows with both moves on it, and whole
    /// in the room that those panes have not yet. Each move of a mask has the spring of its act; a move with the
    /// first close's timing starts when that close's move started.
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

        let before = CACurrentMediaTime()
        _ = try #require(harness.model.showPaneClose(between.closes), "SETUP: the model does not show the close of \(between.closes)")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let after = CACurrentMediaTime()
        let next = try #require(harness.model.focusedPane, "SETUP: no pane has the focus after the first close")
        let second = try #require(rest[next], "SETUP: the pane \(next) that has the focus after the first close did not show at rest")
        try #require(second !== first, "SETUP: the pane that closed keeps the focus")
        _ = try #require(harness.model.showPaneClose(next), "SETUP: the model does not show the close of \(next) in the first close's move")
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(first.isLeaving && !first.isHidden && second.isLeaving && !second.isHidden, "SETUP: the move does not keep the 2 panes that left")
        let acts = Self.acts(on: screen)
        try #require(acts.count == 2, "SETUP: the panes have the moves of \(acts.count) acts, not of the 2 closes: \(acts)")

        for (early, late) in [(0.5, 0), (0.75, 0.25), (0.9, 0.5), (1, 0.75), (1, 1)] as [(CGFloat, CGFloat)] {
            Self.expectKept([first, second], on: screen, "with the first close at \(early) and the second at \(late)") { $0 == acts[1] ? late : early }
        }

        // The pane hosts' own moves say each act's spring; a mask's move with that act's number has it too.
        var springs: [Int: Set<String>] = [:]
        for layer in Self.hosts(of: screen).values.compactMap(\.layer) {
            for key in layer.animationKeys() ?? [] {
                guard let act = Self.act(of: key), let animation = layer.animation(forKey: key) as? CABasicAnimation else { continue }
                springs[act, default: []].insert(Self.pace(animation))
            }
        }
        for mask in [first, second].compactMap({ Self.keptMask(of: $0) }) {
            for layer in [mask] + Self.layers(in: mask) {
                for key in layer.animationKeys() ?? [] {
                    guard let animation = layer.animation(forKey: key) as? CABasicAnimation else { continue }
                    let act = try #require(Self.act(of: key), "the move `\(key)` of a mask names no act")
                    #expect(springs[act]?.contains(Self.pace(animation)) == true,
                            "the mask's move `\(key)` is \(Self.pace(animation)); the panes' moves of the act \(act) are \(springs[act]?.sorted() ?? [])")
                    let began = animation.beginTime
                    if act == acts[1] {
                        #expect(began == 0, "the mask's move `\(key)` of the second close starts at \(began), not with the panes' moves of that close")
                    } else {
                        #expect(began >= before && began <= after, "the mask's move `\(key)` starts at \(began); the first close's move began between \(before) and \(after)")
                    }
                }
            }
        }
    }

    /// A change in the move takes a kept pane back into the layout: an unzoom in the zoom's move, and, in a close's
    /// move, the layout with the closed pane again (a close that was refused). In the frame that shows that
    /// change the pane has no mask on its clip: it shows whole again. After the close the panes still move in that
    /// frame: the motion did not end, so its end did not take the mask.
    @Test(arguments: [true, false])
    func aPaneThatComesBackInTheMoveHasNoMask(zoomed: Bool) throws {
        let alone = try Self.alone(zoomed: zoomed)
        defer { alone.harness.window.closeAfterTest() }
        let left = try #require(alone.screen.subviews.compactMap { $0 as? PaneHostView }.first { $0 !== alone.host && !$0.isHidden },
                                "SETUP: the pane that left does not show in the move")
        try #require(Self.keptMask(of: left) != nil, "SETUP: in the move the pane that left has no mask on its clip")
        alone.harness.model.apply(screens: Commit.pair)
        alone.harness.root.syncWithModel()
        _ = alone.harness.root.advanceFrame(Self.dt)
        try #require(!left.isLeaving && !left.isHidden, "SETUP: the change did not take the pane back")
        if !zoomed { try #require(Self.inFlight(alone.screen), "SETUP: the motion ended in the frame that shows the pane again") }
        #expect(left.clipView.layer?.mask == nil, "in the frame that shows the pane again it keeps a mask on its clip")
    }

    /// A kept pane that no pane moves over gets no mask: a mask costs a pass of its own in each frame of the move.
    /// 3 columns side by side that do not fill the screen, and the first and the last close in one turn: the middle
    /// column goes over the first one's place, and nothing goes over the last one's.
    @Test func aKeptPaneThatNoPaneMovesOverHasNoMask() throws {
        func strip(_ numbers: [Int]) -> [LayoutScreen] {
            let columns = numbers.map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.3, root: .leaf(PaneID("p\($0)"))) }
            return [LayoutScreen(id: "s", name: "s", layout: .columns(columns), zoomed: false)]
        }
        let harness = Commit.Harness(strip([1, 2, 3]), focused: "p2", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.hosts(of: screen)
        let first = try #require(rest["p1"], "SETUP: the first column's pane does not show at rest")
        let middle = try #require(rest["p2"], "SETUP: the middle column's pane does not show at rest")
        let last = try #require(rest["p3"], "SETUP: the last column's pane does not show at rest")
        let place = last.frame

        harness.model.apply(screens: strip([2]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(first.isLeaving && !first.isHidden && last.isLeaving && !last.isHidden, "SETUP: the move does not keep the 2 panes that left")
        let move = try #require(middle.layer.map { Self.move(of: $0) }, "SETUP: the middle pane has no layer")
        try #require(move.moves && Self.area(move.end.intersection(first.frame)) > 1, "SETUP: the middle pane does not move over the first one's place: \(move.start) to \(move.end)")
        try #require(Self.area(move.start.union(move.end).intersection(place)) < 1, "SETUP: the middle pane is over the last one's place \(place): \(move.start) to \(move.end)")
        try #require(Self.keptMask(of: first) != nil, "SETUP: the pane that the middle one moves over has no mask on its clip")
        #expect(last.clipView.layer?.mask == nil, "the kept pane that no pane moves over has a mask on its clip")
    }
}
