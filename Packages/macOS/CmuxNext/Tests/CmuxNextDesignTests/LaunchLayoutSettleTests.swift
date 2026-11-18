import AppKit
@testable import CmuxNextDesign
import Testing

/// A launch harness's settle marks (`layout.*`, LaunchLayoutSettle): the last change after the first frame, the
/// largest move and the view that made it, and when the watch stops.
@Suite struct LaunchLayoutSettleTests {
    @Test func aLaunchWithNoChangeSettlesAtItsFirstFrame() {
        var tally = LaunchLayoutSettleTally()
        tally.first(at: 500)
        #expect(!tally.isOver(at: 1_999))
        #expect(tally.isOver(at: 2_000))
        let marks = Dictionary(uniqueKeysWithValues: tally.marks())
        #expect(marks["layout.first_frame"] == 500)
        #expect(marks["layout.settle"] == 500)
        #expect(marks["layout.max_move"] == 0)
        #expect(marks["layout.changed_frames"] == 0)
        #expect(marks["layout.capped"] == nil)
    }

    @Test func theLastChangeIsTheSettleAndTheLargestMoveIsNamed() {
        var tally = LaunchLayoutSettleTally()
        tally.first(at: 500)
        tally.note(at: 600, change: "SidebarContainerView", move: ("SidebarContainerView", 40))
        tally.note(at: 900, change: "TabStripView", move: ("TabStripView", 6))
        // Quiet runs from the last change, not the first frame.
        #expect(!tally.isOver(at: 2_100))
        #expect(tally.isOver(at: 2_400))
        let marks = Dictionary(uniqueKeysWithValues: tally.marks())
        #expect(marks["layout.settle"] == 900)
        #expect(marks["layout.max_move"] == 40)
        #expect(marks["layout.max_move.SidebarContainerView"] == 40)
        #expect(marks["layout.last.TabStripView"] == 900)
        #expect(marks["layout.changed_frames"] == 2)
    }

    @Test func aLaunchStillChangingStopsAtTheCapAndSaysSo() {
        var tally = LaunchLayoutSettleTally()
        tally.first(at: 0)
        for ms in stride(from: 100.0, through: 5_000, by: 100) { tally.note(at: ms, change: "window", move: nil) }
        #expect(tally.isOver(at: LaunchLayoutSettleTally.capMs))
        let marks = Dictionary(uniqueKeysWithValues: tally.marks())
        #expect(marks["layout.capped"] == 5_000)
        #expect(marks["layout.max_move"] == 0)
        #expect(marks["layout.last.window"] == 5_000)
    }

    @MainActor @Test func aViewIsNamedInOneWord() {
        #expect(LaunchLayoutSettle.markName("NSHostingView<ModifiedContent<A, B>>") == "NSHostingView")
        #expect(LaunchLayoutSettle.markName("TabStripView moved 0,0,10,10 -> 0,0,12,10") == "TabStripView")
        #expect(LaunchLayoutSettle.markName("") == "view")
    }

    @Test func nothingIsOverBeforeAFirstFrame() {
        let tally = LaunchLayoutSettleTally()
        #expect(!tally.isOver(at: 60_000))
        #expect(tally.marks().isEmpty)
    }

    @Test func theFarthestEdgeIsTheMove() {
        // A sidebar widened by 40: its right edge moved 40.
        #expect(WindowViewGeometry.edgeMove(from: CGRect(x: 0, y: 0, width: 200, height: 700), to: CGRect(x: 0, y: 0, width: 240, height: 700)) == 40)
        // A row pushed down 32 (and up the flipped axis): both its edges moved 32.
        #expect(WindowViewGeometry.edgeMove(from: CGRect(x: 0, y: 100, width: 300, height: 28), to: CGRect(x: 0, y: 68, width: 300, height: 28)) == 32)
    }

    @MainActor @Test func theLargestMoveIsTheViewThatMovedFarthest() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let sidebar = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
        let composer = NSView(frame: CGRect(x: 200, y: 0, width: 600, height: 80))
        root.addSubview(sidebar)
        root.addSubview(composer)
        let before = WindowViewGeometry(root: root)
        sidebar.frame.size.width = 240
        composer.frame.origin.x = 240
        composer.frame.size.width = 560
        composer.frame.size.height = 140
        let after = WindowViewGeometry(root: root)
        let move = after.largestMove(since: before)
        #expect(move?.points == 60) // the composer's top edge: 80 -> 140
        #expect(after.largestMove(since: after) == nil)
    }
}
