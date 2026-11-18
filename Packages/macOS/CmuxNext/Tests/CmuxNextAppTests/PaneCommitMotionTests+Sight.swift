import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a strip of columns that is wider than its screen: which pane gets a move when a part of
/// the strip is out of sight. A pane gets no move only when no part of its way can show in the motion's time
/// (`aPaneWhoseWayIsOutOfSightGetsNoMove`). These tests are the cases in which a part of it can.
extension PaneCommitMotionTests {
    /// A strip of the columns `numbers` (column `cN` holds pane `pN`), each half the screen wide. `widths`: the
    /// width of a column that is not, as a part of the screen's width. `roots`: what a column holds when it is not
    /// its one pane.
    static func columns(_ numbers: [Int], widths: [Int: Double] = [:], roots: [Int: SplitNode] = [:]) -> [LayoutScreen] {
        let all = numbers.map { number in
            LayoutColumn(id: ColumnID("c\(number)"), width: widths[number] ?? 0.5, root: roots[number] ?? SplitNode.leaf(PaneID("p\(number)")))
        }
        return [LayoutScreen(id: "s", name: "s", layout: .columns(all))]
    }

    /// A screen at rest at the strip `screens`, with the focus in `focused` and the panes' move on. The columns that
    /// stay at a change keep their widths.
    static func strip(_ screens: [LayoutScreen], focused: PaneID) -> Commit.Harness {
        let harness = Commit.Harness(screens, focused: focused, holds: false) { $0.rowsEnabledOverride = true }
        harness.model.newColumnWidthModeOverride = .matchCurrent
        movePanes(harness)
        Commit.rest(harness)
        return harness
    }

    /// Two new columns after the first column, the second one frame after the first (a hold of the key). The first
    /// puts the column behind it on a way that ends out of sight. The second moves that column again, and all of that
    /// second way is out of sight. The pane still shows on its first way, so it gets the second act's move too: it
    /// goes on from where it shows and does not jump to the end of its first way.
    @Test func aPaneStillOnItsWayOutOfSightGoesOnAtASecondAct() throws {
        let harness = Self.strip(Self.columns([1, 2]), focused: "p1")
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Self.columns([1, 7, 2], widths: [7: 0.75]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let layer = try #require(Self.hosts(of: screen)["p2"]?.layer, "SETUP: the column behind the new one does not show after the first act")
        let first = Set(layer.animationKeys() ?? []), placed = layer.frame
        try #require(Self.move(of: layer).moves && !placed.intersects(screen.bounds),
                     "SETUP: the first new column did not put the column behind it on a way that ends out of sight: it is at \(placed)")

        harness.model.apply(screens: Self.columns([1, 7, 8, 2], widths: [7: 0.75]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(layer.frame != placed && !placed.union(layer.frame).intersects(screen.bounds),
                     "SETUP: the second new column did not move the pane on a way that is all out of sight: \(placed) to \(layer.frame)")
        let now = Set(layer.animationKeys() ?? [])
        try #require(!first.isEmpty && first.isSubset(of: now), "SETUP: the first act's move is off the layer in the frame that shows the second act")
        let second = Self.move(of: layer, only: now.subtracting(first))
        #expect(second.moves, "the second act put no move on a pane that still shows on its way from the first act: the pane jumps")
        #expect(Commit.near(second.start, placed), "the second act's move starts at \(second.start), not at the rect the first act gave the pane: \(placed)")
    }

    /// A new column that is out of sight gets the focus, so the strip's camera goes to it. The pass that shows the
    /// new column places it out of sight, and the camera's way brings it into sight in the motion's time. The new
    /// pane gets its move: it opens while it comes into sight.
    @Test func aPaneThatTheCameraBringsIntoSightKeepsItsMove() throws {
        // The focus is in the first column, so the camera rests at the strip's start.
        let harness = Self.strip(Self.columns([1, 2, 3, 4]), focused: "p1")
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        try #require(abs(screen.scroll.value) < 0.5 && screen.scroll.target == screen.scroll.value,
                     "SETUP: the strip's camera does not rest at the strip's start: \(screen.scroll)")
        // The order of the daemon's echo of a create: its tree, then the focus. The view reads both in one sync.
        harness.model.apply(screens: Self.columns([1, 2, 3, 7, 4]))
        harness.model.focus("p7", notify: false)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let layer = try #require(Self.hosts(of: screen)["p7"]?.layer, "SETUP: the new column does not show after the frame of its act")
        let left = screen.scroll.target - screen.scroll.value
        try #require(left > 100, "SETUP: the strip's camera is not on its way to the new column: \(screen.scroll)")
        try #require(layer.frame.width > 1 && !layer.frame.intersects(screen.bounds),
                     "SETUP: the new column is not placed, or it is in sight in the frame that shows it: \(layer.frame)")
        try #require(layer.frame.offsetBy(dx: -left, dy: 0).intersects(screen.bounds),
                     "SETUP: the camera's way does not bring the new column into sight: \(layer.frame), \(left) pt left")
        #expect(Self.move(of: layer).moves, "a new pane that the camera brings into sight in the motion's time has no move on its layer")
    }

    /// Two closes, the second one frame after the first. The first moves the last column on a way that is all out
    /// of sight, so that column gets no move and shows at its place. The second brings it into sight: its move starts
    /// at that place.
    @Test func aPaneWithNoMoveStartsFromItsPlaceAtASecondAct() throws {
        let harness = Self.strip(Self.columns([1, 2, 3, 4, 5]), focused: "p1")
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        harness.model.apply(screens: Self.columns([1, 3, 4, 5]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let layer = try #require(Self.hosts(of: screen)["p5"]?.layer, "SETUP: the last column does not show after the first close")
        let placed = layer.frame
        try #require(Self.inFlight(screen) && !Self.move(of: layer).moves && !placed.intersects(screen.bounds),
                     "SETUP: the first close moves no pane, or it moves the last column, or that column is in sight: \(placed)")

        harness.model.apply(screens: Self.columns([1, 5]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(layer.frame.intersects(screen.bounds), "SETUP: the second close did not bring the last column into sight: \(layer.frame)")
        let move = Self.move(of: layer)
        #expect(move.moves, "the column that the second close brings into sight has no move on its layer")
        #expect(Commit.near(move.start, placed), "the column's move starts at \(move.start), not at the place where it showed: \(placed)")
        #expect(Commit.near(move.end, layer.frame), "the column's move ends at \(move.end), not at its layer's frame: \(layer.frame)")
    }

    /// A split in a column that is out of sight makes its pane smaller. The pane's content keeps its own old
    /// picture, so its hold begins before the pane hears a size. The pane gets no move, and the hold ends as each
    /// hold does: one time, in the frame that ends the motion, in a split's time.
    @Test func aHeldPaneOutOfSightIsLetGoAtTheMotionsEnd() throws {
        let harness = Self.strip(Self.columns([1, 2, 3, 4]), focused: "p1")
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.screen)
        let content = try #require(harness.provider.contents["p4"], "SETUP: the last column's pane has no content")
        let holder = Holder(), area = PaneContentAreaView(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        holder.frame = area.bounds
        holder.autoresizingMask = [.width, .height]
        holder.content = content
        area.addSubview(holder)
        content.addSubview(area)
        let sizes = content.sizes.count

        let halves = SplitNode.split(SplitID("far"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p4")), b: .leaf(PaneID("p9")))
        harness.model.apply(screens: Self.columns([1, 2, 3, 4], roots: [4: halves]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let layer = try #require(Self.hosts(of: screen)["p4"]?.layer, "SETUP: the pane that was split does not show")
        try #require(holder.log == ["begin at \(sizes) sizes"], "SETUP: to the frame that shows the split the holder heard \(holder.log)")
        try #require(!layer.frame.intersects(screen.bounds) && !Self.move(of: layer).moves,
                     "SETUP: the pane that got smaller is in sight, or it has a move on its layer: \(layer.frame)")
        var ticks = 0
        while holder.log.count == 1, ticks < Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        let spent = Double(ticks) * Self.dt
        #expect(holder.log == ["begin at \(sizes) sizes", "end"], "after the motion's time the holder heard \(holder.log)")
        #expect(spent >= Self.split.time / 2 && spent <= Self.split.time + 2 * Self.dt,
                "the hold ended \(spent) s after the frame that showed the split; a split's time is \(Self.split.time) s")
    }

    /// The 2 counts in the note of an act that moves: the panes that get a move, and the panes that change.
    static func counts(of note: String) -> (moves: Int, changes: Int)? {
        let words = note.split(separator: " ")
        guard let at = words.firstIndex(of: "moves"), at + 1 < words.count, let moves = Int(words[at + 1]),
              let changes = words.last.flatMap({ Int($0.dropLast()) }) else { return nil }
        return (moves, changes)
    }

    /// What a probe reads of an act while `debug.motion` records: one note with the count of the panes that get a
    /// move and the count of the panes that change. A split in sight moves each pane that it changes. A split in a
    /// column that is out of sight moves none of them.
    @Test func aProbesNoteCountsThePanesThatGetAMove() throws {
        func notes() -> [String] { MotionTrace.notes.map { $0.text }.filter { $0.hasPrefix("layout.commit") } }
        defer { MotionTrace.stop() }
        let begun = try Self.begin(Self.split) { _ in MotionTrace.start() }
        defer { begun.harness.window.closeAfterTest() }
        let near = notes()
        let shown = near.count == 1 ? Self.counts(of: near[0]) : nil
        #expect(shown.map { $0.moves > 0 && $0.moves == $0.changes } == true,
                "a split in sight did not write one note with each pane that changes as a pane that gets a move: \(near)")
        _ = Self.toTheEnd(begun.harness, begun.screen)
        MotionTrace.stop()

        let harness = Self.strip(Self.columns([1, 2, 3, 4]), focused: "p1")
        defer { harness.window.closeAfterTest() }
        MotionTrace.start()
        let halves = SplitNode.split(SplitID("far"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p4")), b: .leaf(PaneID("p9")))
        harness.model.apply(screens: Self.columns([1, 2, 3, 4], roots: [4: halves]))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        let far = notes()
        let hidden = far.count == 1 ? Self.counts(of: far[0]) : nil
        #expect(hidden.map { $0.moves == 0 && $0.changes > 0 } == true,
                "a split out of sight did not write one note with 0 panes that get a move and a count of the panes that change: \(far)")
    }
}
