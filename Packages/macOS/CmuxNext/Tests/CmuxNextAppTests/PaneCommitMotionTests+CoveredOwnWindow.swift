import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// A view that draws in a window of its own over its pane, or in its own layer (`PaneContentOwnWindow`).
@MainActor private final class CoveredOwnWindowView: NSView, PaneContentOwnWindow {
    var drawsInOwnWindow = true
}

/// `PaneCommitMotionTests`, a zoom over a pane whose content draws in a window of its own.
///
/// A window of its own is over the whole host window: the pane that grows does not cover it, and the dim over the
/// other panes does not dim it. So while a zoom's move runs, no pane that the zoom covers shows such content: the
/// content is out of sight (hidden, or under a hidden view), or the zoom shows in one frame.
///
/// These rows read the views only. They do not read the screen: that such a window is over the pane that grows is
/// AppKit's rule for a child window.
extension PaneCommitMotionTests {
    /// What a zoom of p4 over p1 gave, tick by tick.
    private struct CoveredZoom {
        /// Whether the frame that shows the zoom began a move.
        var began = false
        /// For each tick in which a move ran: whether p1's view was in sight (not hidden, and no hidden ancestor).
        var inSight: [Bool] = []
        /// Whether the move ended within the bound, and whether p1's view was in sight after it.
        var ended = false
        var inSightAfter = false

        var note: String {
            let ticks = inSight.map { $0 ? "in sight" : "hidden" }.joined(separator: ", ")
            return "the move began: \(began); p1's view at each tick of the move: [\(ticks)]; the move ended after \(inSight.count) ticks: \(ended); "
                + "p1's view after the end: \(inSightAfter ? "in sight" : "hidden")"
        }
    }

    /// The 2 by 2 grid at rest, p1 with a view over its whole content that draws in a window of its own
    /// (`ownWindow`) or in its own layer, then a zoom of p4, stepped to the end of its move.
    private static func zoomOverAPane(ownWindow: Bool) throws -> CoveredZoom {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.root.screenViews["s"], "SETUP: the shown screen has no view")
        let content = try #require(harness.provider.contents["p1"], "SETUP: p1 has no content")
        let view = CoveredOwnWindowView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        view.drawsInOwnWindow = ownWindow
        content.addSubview(view)
        try #require(view.window != nil && !view.isHiddenOrHasHiddenAncestor, "SETUP: p1's view is not in sight before the zoom")
        try #require(content.paneRidesCommitMotion == !ownWindow,
                     "SETUP: p1 rides: \(content.paneRidesCommitMotion); with a view that draws in a window of its own: \(ownWindow)")
        try #require(harness.provider.contents["p4"]?.paneRidesCommitMotion == true, "SETUP: p4, the pane that zooms, does not ride")

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(dt)
        var read = CoveredZoom()
        read.began = inFlight(screen)
        while inFlight(screen), read.inSight.count < Commit.frames {
            read.inSight.append(!view.isHiddenOrHasHiddenAncestor)
            _ = harness.root.advanceFrame(dt)
        }
        read.ended = !inFlight(screen)
        read.inSightAfter = !view.isHiddenOrHasHiddenAncestor
        return read
    }

    /// A zoom that covers a pane whose content draws in a window of its own shows that content in no tick of a move.
    @Test func aZoomsMoveShowsNoCoveredContentThatDrawsInAWindowOfItsOwn() throws {
        let read = try Self.zoomOverAPane(ownWindow: true)
        print("covered own window, row 1: \(read.note)")
        #expect(!(read.began && read.inSight.contains(true)),
                "a zoom moves its pane while a pane that it covers shows content in a window of its own: \(read.note)")
    }

    /// The control: the same view in its own layer. The zoom moves its pane, and the covered pane shows to the move's end.
    @Test func aZoomMovesItsPaneOverCoveredContentThatDrawsInItsOwnLayer() throws {
        let read = try Self.zoomOverAPane(ownWindow: false)
        print("covered own window, row 2: \(read.note)")
        #expect(read.began && !read.inSight.isEmpty && read.ended, "a zoom over content in its own layer has no move, or its move does not end: \(read.note)")
        #expect(read.inSight.allSatisfy { $0 }, "a covered pane's content in its own layer is not in sight in each tick of the zoom's move: \(read.note)")
    }
}
