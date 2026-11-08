#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 7 (fork only, never merged): the G4P Z4 zoom in's key turn moved the divider catcher panels (ZV6 Time
/// Profiler, n=10: `WindowOverlayLayer.syncCatchers` 0.7 ms per press, parking each panel: a window server frame, tags and
/// mouse flag each), work the first moved frame does not show. A spring zoom already leaves the catchers until it lands
/// (`DividerCatcherMotionTests`: nobody grabs a divider on a spring); the film zoom snaps the layout in the key's turn and
/// plays on layers, so the catchers followed the snapped dividers at once. While a film zoom plays, the window's catcher
/// areas stay as they were; they follow once, when the film ends.
@MainActor @Suite(.serialized, .closesItsWindows) struct FilmZoomCatcherTurnTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shell window whose content is a 2x2 split layout, its overlay layer adopting the layout's plane, as the app wires
    /// them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        init() {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ZoomKeepsCoveredPanesTests.four))],
                                activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true // the test is the clock: the display link never ticks
            land()
        }

        func land() {
            var frames = 0
            while frames < 600, root.advanceFrame(1.0 / 120) { frames += 1 }
        }

        func show(_ tree: SplitNode, zoomed: Bool) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree), zoomed: zoomed)])
            root.syncWithModel()
        }

        var catcherAreas: [CGRect] { window.overlayLayer.catcherAreas.map(\.rect) }
        var dividerAreas: [CGRect] { window.overlayLayer.dividerAreas.map(\.rect) }
    }

    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func theZoomKeyTurnLeavesTheCatchersWhereTheyWere(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let layout = Layout()
        defer { layout.window.close() }
        let before = layout.catcherAreas
        try #require(before.count >= 2, "the 2x2 layout's dividers have catcher areas: \(layout.dividerAreas)")

        // Zoom in: the key's turn snaps the layout (no divider shows) and the next tick's presentation starts the film.
        layout.show(.leaf("p1"), zoomed: true)
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(!layout.root.screenViews["s"]!.frameInput.filmZoomFading.isEmpty, "Z4 zoom in plays its film")
        #expect(layout.catcherAreas == before, "the zoom's key turn moved the catcher panels: \(before) -> \(layout.catcherAreas)")
    }
}
#endif
