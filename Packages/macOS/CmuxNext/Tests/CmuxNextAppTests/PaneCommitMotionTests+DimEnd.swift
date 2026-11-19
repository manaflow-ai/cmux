import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, the end of an unzoom's dim.
///
/// The dim over the other panes goes on a fade from the frame that shows the unzoom. The pane that closes to its
/// place moves on the unzoom's spring from the same frame. The two end in one frame: a dim that still shows when the
/// pane is at its place is a frame with a part of the unzoom on the screen. So the dim's fade takes at most the time
/// that the motion has left, by the motion's own count, and the tick that ends the move takes the dim away. An unzoom
/// whose pane does not move keeps the pane veil's fade (`PaneZoomDimTests`).
extension PaneCommitMotionTests {
    /// An unzoom whose pane moves: in the frame that shows it, the dim's fade on its layer is not longer than the
    /// move of the pane that closes, and at the tick that ends the move no dim shows.
    @Test func anUnzoomsDimIsGoneAtTheTickThatEndsItsPanesMove() throws {
        let unzoom = try Self.unzooming(frames: 1)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        try #require(Self.inFlight(screen), "SETUP: the pane that closes has no move in the frame that shows the unzoom")
        let dim = try #require(Dim.dim(harness), "SETUP: the frame that shows the unzoom shows no dim")
        let going = try #require(dim.layer.animation(forKey: "opacity") as? CABasicAnimation, "SETUP: the dim goes with no fade on its layer")
        let layer = try #require(unzoom.host.layer, "SETUP: the pane that closes has no layer")
        let length = try #require(Self.move(of: layer).animations.map(\.duration).max(), "SETUP: the pane that closes has no move on its layer")
        #expect(going.duration <= length + 1e-6,
                "the dim's fade is over \(going.duration) s; the move of the pane that closes is over \(length) s: the dim shows after the move's end")
        let end = Self.toTheEnd(harness, screen)
        #expect(!Self.inFlight(screen) && Dim.dim(harness) == nil,
                "at the tick that ends the unzoom's move (\(end.ticks) ticks after the frame that showed it) a dim shows")
    }

    /// A second zoom key in a zoom's move, with a pane that gives its last frame: the zoom's dim goes from the
    /// strength it shows, and at the tick that ends the motion the grid shows with no dim.
    @Test func aSecondKeyInAZoomsMoveEndsTheDimWithTheMotion() throws {
        let zoom = try Self.zooming(frames: 3)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        try #require(Self.inFlight(screen) && Dim.dim(harness) != nil, "SETUP: three frames after the zoom key the pane does not move under a dim")
        let content = try #require(harness.provider.contents["p4"], "SETUP: the zoomed pane has no content")
        let area = PaneContentAreaView(frame: content.bounds), picture = Picture(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        picture.autoresizingMask = [.width, .height]
        area.addSubview(picture)
        content.addSubview(area)

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.inFlight(screen) && Dim.dim(harness) != nil, "SETUP: the frame that shows the unzoom has no move, or no dim")
        let end = Self.toTheEnd(harness, screen)
        #expect(!Self.inFlight(screen) && zoom.grid.isShown(by: Commit.shown(screen)), "after the motion's end the screen does not show the grid alone")
        #expect(Dim.dim(harness) == nil, "at the tick that ends the motion (\(end.ticks) ticks after the frame that showed the unzoom) a dim shows")
    }
}
