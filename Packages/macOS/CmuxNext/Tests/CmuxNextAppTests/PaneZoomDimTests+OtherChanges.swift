import AppKit
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneZoomDimTests`, the dim with another change around it: a zoom on a canvas, which gets no dim. A zoom key while
/// an unzoom's dim still goes and a close of the pane that zooms are rows of `PaneCommitMotionTests+Zoom`.
extension PaneZoomDimTests {
    /// A zoom on a canvas comes and goes with no dim. The canvas's camera changes in the zoom's own turn, so the
    /// screen cannot go on showing the layout before the zoom under a dim: the zoomed pane shows alone in the first
    /// frame, and its unzoom shows every pane again in its first frame. Where a canvas shows its panes is not read here.
    @Test func aZoomOnACanvasComesAndGoesWithNoDim() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        // The app's own way into a canvas: its panes start where they show.
        let seed = harness.root.canvasSeed(for: "s")
        try #require(harness.model.toggleCanvas(screen: "s", seed: seed?.frames ?? [:], viewport: seed?.viewport ?? .zero),
                     "SETUP: the model did not make the screen a canvas")
        harness.root.syncWithModel()
        Commit.rest(harness)
        // Without these two the test proves nothing: a tiled screen in this state gets a dim at its unzoom (`anUnzoomShowsEveryPaneUnderADimThatFades`).
        try #require(screen.isCanvas && screen.zoomDim.fade(on: screen) > 0, "SETUP: the screen shows no canvas, or panes do not animate")
        let all = Set(Commit.shown(screen).panes.keys)
        try #require(all == ["p1", "p2", "p3", "p4"], "SETUP: the canvas does not show its four panes: \(all)")

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the zoom key on a canvas shows a dim")
        _ = harness.root.advanceFrame(Self.dt)
        var shown = Commit.shown(screen)
        #expect(Set(shown.panes.keys) == ["p4"], "the first frame after the zoom key on a canvas does not show the zoomed pane alone: \(shown.panes)")
        #expect(Self.dim(harness) == nil, "the frame that shows a zoom on a canvas shows a dim")
        Commit.rest(harness)

        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the unzoom key on a canvas shows a dim")
        _ = harness.root.advanceFrame(Self.dt)
        shown = Commit.shown(screen)
        #expect(Set(shown.panes.keys) == all, "the first frame after the unzoom on a canvas does not show every pane: \(shown.panes)")
        #expect(Self.dim(harness) == nil, "the frame that shows an unzoom on a canvas shows a dim")
        for tick in 2...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            #expect(Self.dim(harness) == nil, "tick \(tick) after the unzoom on a canvas shows a dim")
        }
    }
}
