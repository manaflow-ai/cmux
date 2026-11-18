import AppKit
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneZoomDimTests`, the dim with another change around it: a zoom key while an unzoom's dim still goes, a close of
/// the pane that zooms while the dim comes, and a zoom on a canvas, which gets no dim.
extension PaneZoomDimTests {
    /// A zoom key while an unzoom's dim still goes: the dim stays over the other panes and comes again, so no frame
    /// between the two shows the grid with no dim. From that key on the frames are a zoom's: the grid, whole, under
    /// the dim for the dim's whole time, then one frame that shows the zoomed pane alone with no dim.
    ///
    /// Not read here: the strength the dim's fade starts from. It is the strength the screen shows at that key, which
    /// only the render server has, and a test function commits nothing to it.
    @Test func aZoomKeyWhileAnUnzoomsDimGoesBringsTheDimAgain() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let fade = try Self.fade()
        let grid = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        Commit.rest(harness)
        try #require(zoomed.isShown(by: Commit.shown(screen)) && Self.dim(harness) == nil, "SETUP: the zoom did not come to rest with no dim")
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.dim(harness) != nil && grid.isShown(by: Commit.shown(screen)), "SETUP: two frames after the unzoom its dim does not show over the grid")
        // The grid's places, read while each pane has its host: the zoom's own turn must leave every pane there.
        let places = try Self.places(clear: "p4", over: ["p1", "p2", "p3"], in: harness)

        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        harness.root.syncWithModel()
        // The key's own turn: nothing moved, and the dim comes over the other panes.
        #expect(grid.isShown(by: Commit.shown(screen)), "the zoom's own turn changed what the screen shows")
        let dim = try #require(Self.dim(harness), "the zoom's own turn shows no dim over the other panes")
        #expect(dim.layer.opacity > 0.05, "the dim does not come: its strength goes to \(dim.layer.opacity)")
        let off = Self.misses(dim, places)
        #expect(off.isEmpty, "\(off)")

        // Each frame shows the grid, whole, under the dim, until one frame shows the zoomed pane alone with no dim.
        var shownAt: Int?
        for tick in 1...Commit.frames {
            let asks = harness.root.advanceFrame(Self.dt)
            let frame = Commit.shown(screen)
            if zoomed.isShown(by: frame) {
                if shownAt == nil { shownAt = tick }
                #expect(Self.dim(harness) == nil, "tick \(tick): the dim still shows with the zoomed pane")
                #expect(!asks, "tick \(tick): a zoom that showed asks for frames")
            } else {
                #expect(shownAt == nil && grid.isShown(by: frame), "tick \(tick) shows neither layout, or the grid again: \(frame.panes)")
                #expect(Self.dim(harness) != nil, "tick \(tick): the dim went before the zoom showed")
                #expect(asks, "tick \(tick): the zoom waits and asks for no frame")
            }
            #expect(frame.misfits.isEmpty, "tick \(tick): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
        }
        let at = try #require(shownAt, "the zoom never showed")
        // The dim's whole time from this key, whatever was left of the unzoom's.
        #expect(at == Self.ticks(of: fade) + 1, "the zoom showed at tick \(at); the dim's fade is \(fade) s, \(Self.ticks(of: fade)) ticks")
        #expect(harness.provider.released.isEmpty, "a pane was released: \(harness.provider.released)")
    }

    /// The pane that zooms closes while the dim comes. Its close comes with the daemon's tree: the model shows no
    /// close of a zoomed pane itself. The dim ends in that turn, and the close is a layout change of its own: the
    /// screen goes on showing the grid, whole and with no dim, and the next frame shows the panes that stay at their
    /// places, with no frame between the two.
    @Test func aCloseOfThePaneThatZoomsWhileTheDimComesEndsIt() throws {
        let (harness, screen, grid) = try Self.whileTheDimComes()
        defer { harness.window.closeAfterTest() }
        // The grid less p4: p3 takes the whole right half.
        let stays: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                      a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), b: .leaf("p3"))
        harness.model.apply(screens: Commit.screen(stays))
        let closed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(Self.dim(harness) == nil, "the dim stays after the pane that zooms closed")
        var frame = Commit.shown(screen)
        #expect(grid.isShown(by: frame), "the close's own turn shows another layout than the grid: \(frame.panes)")
        for tick in 1...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            frame = Commit.shown(screen)
            #expect(closed.isShown(by: frame), "tick \(tick) does not show the panes that stay at their places: \(frame.panes)")
            #expect(frame.misfits.isEmpty, "tick \(tick): a pane's content is not at the rect its pane gives it: \(frame.misfits)")
            #expect(Self.dim(harness) == nil, "tick \(tick): a dim shows after the pane that zooms closed")
        }
    }

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
        // Without these two the test proves nothing: a tiled screen in this state gets a dim (the tests beside this one).
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
