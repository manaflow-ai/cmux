import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A catcher panel takes the mouse from a page window over a divider; a page that is not over the window's content
/// covers no divider, so it gets none. A zoom takes every divider out and an unzoom brings them back, each in one
/// frame: with only the New Tab spare's page, parked 100 000 pt outside the window (`PageOffscreenParking`), neither
/// moves, parks or makes a panel.
/// History, RESIZE VIDEOS Z1 (feat e34fecc1312, 4 of 4 films: one frame of 29-33 ms at each zoom and unzoom landing of
/// 12 terminal panes; Time Profiler: 13-14 ms of that frame's 14-15 ms main thread, idle,
/// in `setLayoutInMotion(false)` -> `WindowOverlayLayer.syncCatchers` -> `DividerMouseCatchers.update`): the zoom parked
/// 11 divider catcher panels and the unzoom showed or made 11 again (a window server order, frame or new window each),
/// though no pane showed a page.
/// The test is the clock (120 Hz).
@MainActor @Suite(.serialized, .closesItsWindows) struct ParkedPageCatcherPanelsTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let four: SplitNode = .split("r", axis: .horizontal, ratio: 0.5,
                                        a: .split("a", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                        b: .split("b", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    /// A shown shell window with four panes (three dividers) and one page child window at `pageFrame` (screen
    /// coordinates, from the parent's frame), as the Chromium fork adds one.
    final class Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let page: NSWindow
        private let provider = Panes()

        init(pageFrame: (CGRect) -> CGRect) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(ParkedPageCatcherPanelsTests.four))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            page = NSWindow(contentRect: pageFrame(window.frame), styleMask: [.borderless], backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            window.addChildWindow(page, ordered: .above)
            window.overlayLayer.evaluate()
            land()
        }

        func close() {
            window.overlayLayer.teardown() // as WindowController.teardown does when the window closes: its catcher panels close
            window.removeChildWindow(page)
            page.close()
            window.close()
        }

        var catchers: DividerMouseCatchers { window.overlayLayer.catchers }

        func show(_ tree: SplitNode, zoomed: Bool) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree), zoomed: zoomed)])
            root.syncWithModel()
        }

        /// Steps frames until one asks for no more (`frame` runs after each). Returns the catcher panel window changes
        /// (moves, parks, new panels) made in each frame.
        @discardableResult
        func land(each frame: () -> Void = {}) -> [Int] {
            var changes: [Int] = []
            var moving = true
            while moving, changes.count < 600 {
                let before = catchers.panelUpdates + catchers.panelsMade
                moving = root.advanceFrame(1.0 / 120)
                changes.append(catchers.panelUpdates + catchers.panelsMade - before)
                frame()
            }
            return changes
        }
    }

    /// The New Tab spare's page, parked far outside the window (`PageOffscreenParking.frame`).
    static func parked(_ parent: CGRect) -> CGRect {
        CGRect(x: parent.minX - 100_000, y: parent.minY - 100_000, width: parent.width, height: parent.height)
    }

    /// A zoom and an unzoom each show in one frame, and neither changes a catcher panel window: not in its own turn, not
    /// in the frame that shows it, and not in the frames of the dim around it (the dim comes over the other panes before
    /// a zoom shows, and goes after an unzoom showed).
    @Test func aZoomAndAnUnzoomMoveNoCatcherPanelForAParkedPage() throws {
        let layout = Layout(pageFrame: Self.parked)
        defer { layout.close() }
        // As in the app: a parked page is a page child window, so the window is in page mode.
        try #require(layout.window.overlayLayer.placement == .overlayWindow, "the parked page did not put the window in page mode")
        try #require(layout.window.overlayLayer.catcherAreas.count >= 3, "the dividers have catcher areas: \(layout.window.overlayLayer.catcherAreas)")
        #expect(layout.catchers.framesInWindow.isEmpty,
                "no page is over the window's content, yet dividers have catcher panels: \(layout.catchers.framesInWindow)")
        let screen = try #require(layout.root.screenViews["s"])
        // The four panes and their dividers at rest: what each frame shows is read against it.
        let grid = PaneLayoutCommitTests.shown(screen)

        // Each change is counted from before its own turn to the end of its last frame.
        var count = layout.catchers.panelUpdates + layout.catchers.panelsMade
        layout.show(.leaf("p1"), zoomed: true)
        var zoomShown: [PaneLayoutCommitTests.Frame] = []
        let zoomFrames = layout.land { zoomShown.append(PaneLayoutCommitTests.shown(screen)) }
        let zoom = layout.catchers.panelUpdates + layout.catchers.panelsMade - count
        count += zoom
        layout.show(Self.four, zoomed: false)
        var unzoomShown: [PaneLayoutCommitTests.Frame] = []
        let unzoomFrames = layout.land { unzoomShown.append(PaneLayoutCommitTests.shown(screen)) }
        let unzoom = layout.catchers.panelUpdates + layout.catchers.panelsMade - count
        // The zoom shows in one frame, its last: each frame before it (the dim comes) keeps every pane and divider where
        // it was. The unzoom shows in its first frame, and no pane moves in the frames its dim takes to go. Each is over
        // in 40 frames.
        #expect(zoomFrames.count <= 40 && zoomShown.dropLast().allSatisfy { PaneLayoutCommitTests.same($0, grid) },
                "a zoom did not show in one frame: it took \(zoomFrames.count) frames, or a frame before its last one moved a pane or a divider")
        #expect(zoomShown.last?.panes.count == 1 && zoomShown.last?.dividers.isEmpty == true,
                "the last frame of the zoom does not show the zoomed pane alone: \(zoomShown.last?.panes ?? [:])")
        #expect(unzoomFrames.count <= 40 && unzoomShown.allSatisfy { PaneLayoutCommitTests.same($0, grid) },
                "an unzoom did not show in its first frame, or a pane moved after it: \(unzoomFrames.count) frames")
        #expect(zoom == 0, "the zoom changed \(zoom) catcher panel windows (in its frames: \(zoomFrames))")
        #expect(unzoom == 0, "the unzoom changed \(unzoom) catcher panel windows (in its frames: \(unzoomFrames))")
    }

    /// The control: a page over the window's content still gets a panel over each divider area.
    @Test func aPageOverTheContentKeepsItsCatcherPanels() throws {
        let layout = Layout(pageFrame: { $0.insetBy(dx: 40, dy: 40) })
        defer { layout.close() }
        let areas = layout.window.overlayLayer.catcherAreas
        try #require(areas.count >= 3, "the dividers have catcher areas: \(areas)")
        #expect(layout.catchers.framesInWindow.count == areas.count,
                "every divider area over a page has a panel: \(layout.catchers.framesInWindow.count) of \(areas.count)")
    }

    /// A page over one side of the window: only the divider areas it covers get a panel (a terminal pane's divider
    /// across the window has no page to take its mouse).
    @Test func onlyTheDividerAreasAPageCoversGetPanels() throws {
        let layout = Layout(pageFrame: { CGRect(x: $0.minX, y: $0.minY, width: $0.width * 0.3, height: $0.height) })
        defer { layout.close() }
        let page = layout.window.convertFromScreen(layout.page.frame)
        let areas = layout.window.overlayLayer.catcherAreas
        let covered = areas.filter { $0.rect.intersects(page) }
        try #require(!covered.isEmpty && covered.count < areas.count, "the page covers some divider areas, not all: \(covered.count) of \(areas.count)")
        #expect(Set(layout.catchers.framesInWindow.keys) == Set(covered.map(\.id)),
                "panels \(layout.catchers.framesInWindow.keys.sorted()), areas the page covers \(covered.map(\.id).sorted())")
    }

    /// A parked page that comes over the content (the spare adopted into a pane) gives the dividers their panels at
    /// the next check of the window's page windows (a page window's move runs it).
    @Test func aParkedPageThatComesOverTheContentGetsCatcherPanels() throws {
        let layout = Layout(pageFrame: Self.parked)
        defer { layout.close() }
        layout.page.setFrame(layout.window.frame.insetBy(dx: 40, dy: 40), display: false)
        layout.window.overlayLayer.evaluate()
        let areas = layout.window.overlayLayer.catcherAreas
        try #require(areas.count >= 3)
        #expect(layout.catchers.framesInWindow.count == areas.count,
                "the adopted page's dividers have panels: \(layout.catchers.framesInWindow.count) of \(areas.count)")
    }
}
