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

    // MARK: One frame beside a window of its own

    /// The 2 by 2 grid at rest with the panes' move on, and one pane with a view over its whole content.
    private struct ViewedGrid {
        let harness: Commit.Harness
        let screen: ScreenContentView
        let view: CoveredOwnWindowView
    }

    /// `pane`'s view draws in a window of its own (`ownWindow`) or in its own layer. A dim can fade on this screen.
    private static func viewedGrid(in pane: PaneID, ownWindow: Bool) throws -> ViewedGrid {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        var made = false
        defer { if !made { harness.window.closeAfterTest() } }
        movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.root.screenViews["s"], "SETUP: the shown screen has no view")
        let content = try #require(harness.provider.contents[pane], "SETUP: \(pane) has no content")
        let view = CoveredOwnWindowView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        view.drawsInOwnWindow = ownWindow
        content.addSubview(view)
        try #require(view.window != nil && !view.isHiddenOrHasHiddenAncestor, "SETUP: \(pane)'s view is not in sight before the zoom")
        try #require(content.paneRidesCommitMotion == !ownWindow,
                     "SETUP: \(pane) rides: \(content.paneRidesCommitMotion); with a view that draws in a window of its own: \(ownWindow)")
        _ = try Dim.fade()
        try #require(screen.zoomDim.fade(on: screen) > 0, "SETUP: no dim can fade on this screen")
        made = true
        return ViewedGrid(harness: harness, screen: screen, view: view)
    }

    /// The zoom key on p4 and the frame that shows the zoom. Returns the zoom at rest at the screen's size.
    private static func showZoom(_ harness: Commit.Harness, on screen: ScreenContentView) -> Commit.Rest {
        harness.model.apply(screens: Zoom.screens(zoomedOn: "p4"))
        let zoomed = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(dt)
        return zoomed
    }

    /// A zoom over a pane whose content draws in a window of its own shows in one frame: the frame that shows it has
    /// the zoomed pane alone (each pane that the zoom covers is out of sight, its view with it), no move and no dim.
    @Test func aZoomOverContentInAWindowOfItsOwnShowsInOneFrameWithNoDim() throws {
        let grid = try Self.viewedGrid(in: "p1", ownWindow: true)
        let harness = grid.harness, screen = grid.screen
        defer { harness.window.closeAfterTest() }
        let zoomed = Self.showZoom(harness, on: screen)
        #expect(!Self.inFlight(screen), "a zoom moves its pane over a pane whose content draws in a window of its own")
        #expect(zoomed.isShown(by: Commit.shown(screen)), "the frame that shows the zoom does not show the zoomed pane alone: \(Commit.shown(screen).panes)")
        #expect(grid.view.isHiddenOrHasHiddenAncestor, "the frame that shows the zoom has the covered pane's view in sight")
        #expect(Dim.dim(harness) == nil, "a zoom over content in a window of its own shows a dim")
    }

    /// An unzoom that brings back a pane whose content draws in a window of its own shows in one frame, with no dim:
    /// the grid, no move and no last frame. The control (`ownWindow` false), the same view in its own layer: the pane
    /// that had the screen moves under its last frame, and the dim shows over the others.
    @Test(arguments: [true, false])
    func anUnzoomBesideContentInAWindowOfItsOwnShowsInOneFrameWithNoDim(_ ownWindow: Bool) throws {
        let unzoom = try Self.unzooming(frames: 0)
        let harness = unzoom.zoom.harness, screen = unzoom.zoom.screen
        defer { harness.window.closeAfterTest() }
        _ = try Dim.fade()
        try #require(screen.zoomDim.fade(on: screen) > 0, "SETUP: no dim can fade on this screen")
        // The key's turn is done and no frame showed the unzoom yet: p1 comes back with this view.
        let content = try #require(harness.provider.contents["p1"], "SETUP: p1 has no content")
        let view = CoveredOwnWindowView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        view.drawsInOwnWindow = ownWindow
        content.addSubview(view)
        _ = harness.root.advanceFrame(Self.dt)
        #expect(unzoom.zoom.grid.isShown(by: Commit.shown(screen)), "the frame that shows the unzoom does not show the grid: \(Commit.shown(screen).panes)")
        try #require(!view.isHiddenOrHasHiddenAncestor, "SETUP: p1's view is not in sight in the frame that shows the unzoom")
        let moving = Self.inFlight(screen), last = Self.lastFrames(on: screen).count, dims = Dim.dim(harness) != nil
        #expect(moving == !ownWindow && (last == 0) == ownWindow,
                "an unzoom beside a view that draws in a window of its own (\(ownWindow)): a pane moves: \(moving); last frames: \(last)")
        #expect(dims == !ownWindow, "an unzoom beside a view that draws in a window of its own (\(ownWindow)): a dim shows: \(dims)")
    }

    /// A zoom of a pane whose own content draws in a window of its own shows in one frame, as that pane does not ride
    /// (`NSView.paneRidesCommitMotion`): the zoomed pane alone, no move and no dim.
    @Test func aZoomOfAPaneWithContentInAWindowOfItsOwnShowsInOneFrameWithNoDim() throws {
        let grid = try Self.viewedGrid(in: "p4", ownWindow: true)
        let harness = grid.harness, screen = grid.screen
        defer { harness.window.closeAfterTest() }
        let zoomed = Self.showZoom(harness, on: screen)
        #expect(!Self.inFlight(screen), "a zoom moves a pane whose content draws in a window of its own")
        #expect(zoomed.isShown(by: Commit.shown(screen)), "the frame that shows the zoom does not show the zoomed pane alone: \(Commit.shown(screen).panes)")
        #expect(Dim.dim(harness) == nil, "a zoom of a pane that does not ride shows a dim")
    }

    /// The unzoom of that pane shows in one frame too. The other panes are in the window's layers: the dim shows over
    /// them in that frame, and goes in the pane veil's time.
    @Test func anUnzoomOfAPaneWithContentInAWindowOfItsOwnShowsInOneFrameUnderADimThatGoes() throws {
        let grid = try Self.viewedGrid(in: "p4", ownWindow: true)
        let harness = grid.harness, screen = grid.screen
        defer { harness.window.closeAfterTest() }
        let fade = try Dim.fade()
        let rest = Commit.Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        let zoomed = Self.showZoom(harness, on: screen)
        Commit.rest(harness)
        try #require(zoomed.isShown(by: Commit.shown(screen)) && !Self.inFlight(screen) && Dim.dim(harness) == nil,
                     "SETUP: the zoom did not come to rest with no dim")
        harness.model.apply(screens: Zoom.screens())
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(rest.isShown(by: Commit.shown(screen)), "the first frame after the unzoom key does not show the grid: \(Commit.shown(screen).panes)")
        #expect(!Self.inFlight(screen), "an unzoom moves a pane whose content draws in a window of its own")
        #expect(Dim.dim(harness) != nil, "the frame that shows the unzoom shows no dim over the other panes")
        var goneAt: Int?
        for tick in 2...Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            if goneAt == nil, Dim.dim(harness) == nil { goneAt = tick }
        }
        let gone = try #require(goneAt, "the dim never went")
        #expect(abs(Double(gone - 1) * Self.dt - fade) <= Self.dt + 1e-6,
                "the dim went at tick \(gone) (\(Double(gone - 1) * Self.dt) s after the unzoom showed); its fade is \(fade) s")
    }

    /// A zoom over a pane that does not ride for another cause (its content area shows a view of no riding kind, in
    /// the window's layers) moves its pane, and the dim comes: only a window of its own stops the move.
    @Test func aZoomOverAPaneThatDoesNotRideForAnotherCauseMovesItsPane() throws {
        let harness = Commit.Harness(Zoom.screens(), focused: "p4", holds: false)
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.root.screenViews["s"], "SETUP: the shown screen has no view")
        let content = try #require(harness.provider.contents["p1"], "SETUP: p1 has no content")
        let area = PaneContentAreaView(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        let page = NSView(frame: area.bounds)
        page.autoresizingMask = [.width, .height]
        area.addSubview(page)
        content.addSubview(area)
        try #require(!content.paneRidesCommitMotion, "SETUP: a pane whose area shows a view of no riding kind rides")
        _ = Self.showZoom(harness, on: screen)
        #expect(Self.inFlight(screen), "a zoom over a pane that does not ride, with no window of its own, shows in one frame")
        #expect(Dim.dim(harness) != nil, "the frame that begins the zoom's move shows no dim over the other panes")
    }
}
