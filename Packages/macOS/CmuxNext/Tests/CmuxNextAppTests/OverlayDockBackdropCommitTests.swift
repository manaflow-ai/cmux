import AppKit
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// The glass backdrop under an overlay dock is part of the layout a frame shows. A layout change that takes the dock
/// out of the screen (a zoom of a pane beside it) or brings it back (the unzoom) changes the backdrop in the frame that
/// shows the change, with the dock's panes: no frame shows the dock's panes without their backdrop, or a backdrop under
/// a layout that has no dock.
///
/// The panes a frame shows are read as `PaneLayoutCommitTests` reads them, and the test is the clock: it steps the
/// layout's frames itself.
@MainActor
@Suite(.closesItsWindows) struct OverlayDockBackdropCommitTests {
    typealias Commit = PaneLayoutCommitTests

    /// Two strip columns and an overlay dock at the right edge; with `pane`, that pane alone on its screen (a zoom).
    static func screens(zoomedOn pane: PaneID? = nil) -> [LayoutScreen] {
        let columns = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .overlay)),
        ])
        let layout = pane.map { ScreenLayout.splits(.leaf($0)) } ?? columns
        return [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: pane != nil)]
    }

    /// The frames of the backdrops the screen shows now.
    static func backdrops(_ screen: ScreenContentView) -> [CGRect] {
        screen.subviews.filter { $0 is DockBackdropView && !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 }.map(\.frame)
    }

    @Test func aZoomKeepsTheDocksBackdropUntilTheFrameThatShowsTheZoom() throws {
        let harness = Commit.Harness(Self.screens(), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let glass = Self.backdrops(screen)
        try #require(glass.count == 1, "SETUP: the overlay dock shows \(glass.count) backdrops at rest")
        let before = Commit.shown(screen)
        try #require(before.panes.count == 3, "SETUP: the screen does not show its 3 panes at rest: \(before.panes)")

        harness.model.apply(screens: Self.screens(zoomedOn: "p1"))
        harness.root.syncWithModel()
        // The zoom's own turn: the screen still shows the layout with the dock, whole.
        try #require(Commit.same(Commit.shown(screen), before), "SETUP: the zoom's own turn changed the panes the screen shows")
        #expect(Self.backdrops(screen) == glass, "the zoom's own turn took the backdrop from under the dock's panes: \(Self.backdrops(screen))")

        _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
        try #require(Set(Commit.shown(screen).panes.keys) == ["p1"], "SETUP: the first frame does not show the zoomed pane alone")
        #expect(Self.backdrops(screen).isEmpty, "the frame that shows the zoom still shows the dock's backdrop: \(Self.backdrops(screen))")
    }

    @Test func anUnzoomBringsTheDocksBackdropInTheFrameThatShowsTheUnzoom() throws {
        let harness = Commit.Harness(Self.screens(), focused: "p1", holds: false)
        defer { harness.window.closeAfterTest() }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let glass = Self.backdrops(screen)
        try #require(glass.count == 1, "SETUP: the overlay dock shows \(glass.count) backdrops at rest")
        harness.model.apply(screens: Self.screens(zoomedOn: "p1"))
        harness.root.syncWithModel()
        Commit.rest(harness)
        let zoomed = Commit.shown(screen)
        try #require(Set(zoomed.panes.keys) == ["p1"] && Self.backdrops(screen).isEmpty, "SETUP: the zoom did not come to rest with one pane and no backdrop")

        harness.model.apply(screens: Self.screens())
        harness.root.syncWithModel()
        // The unzoom's own turn: the screen still shows the zoomed pane alone, and that layout has no dock.
        try #require(Commit.same(Commit.shown(screen), zoomed), "SETUP: the unzoom's own turn changed the panes the screen shows")
        #expect(Self.backdrops(screen).isEmpty, "the unzoom's own turn shows a dock's backdrop with the zoomed pane's layout: \(Self.backdrops(screen))")

        _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
        try #require(Commit.shown(screen).panes.count == 3, "SETUP: the first frame does not show the 3 panes again")
        #expect(Self.backdrops(screen) == glass, "the frame that shows the unzoom does not show the dock's backdrop where it was: \(Self.backdrops(screen))")
    }
}
