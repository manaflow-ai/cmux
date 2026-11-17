import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-Enter on terminals. A zoom and an unzoom are one commit each: the key's turn changes no pane on
/// screen, and the frame that shows the change gives the zoomed pane its new size, so its terminal reports
/// one grid to the PTY owner then, the final one. No frame shows the pane at a size between the two, so no
/// grid of such a size goes out (a zoom on a spring once made ~30 PTY resizes, shell redraws and owner
/// reflows, and announcements landing frames behind the view made the text jump).
@MainActor
@Suite(.closesItsWindows)
struct PaneZoomTerminalResizeTests {
    /// A pane's content that sizes like a terminal: each size it takes is a grid
    /// (``TerminalGridPolicy``), held while its pane is on a layout spring.
    final class GridProbe: NSView, PaneMotionSettling {
        var policy = TerminalGridPolicy(ownsGeometry: true)
        var reports: [TerminalGridSize] = []
        var settles = 0
        static let cell = CGSize(width: 8, height: 17)

        var grid: TerminalGridSize {
            TerminalGridSize(columns: max(1, Int(bounds.width / Self.cell.width)), rows: max(1, Int(bounds.height / Self.cell.height)))
        }

        override func setFrameSize(_ newSize: NSSize) {
            let resized = newSize != frame.size
            super.setFrameSize(newSize)
            guard resized, bounds.width >= 1, bounds.height >= 1 else { return }
            if let report = policy.viewSized(grid, holding: isInPaneMotion) { reports.append(report) }
        }

        func paneMotionDidSettle() {
            settles += 1
            if let report = policy.releaseHeld() { reports.append(report) }
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var probes: [PaneID: GridProbe] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let probe = GridProbe()
            probes[pane] = probe
            return probe
        }
    }

    /// A window whose chrome resizes the content area over several frames, as the shell
    /// window does while the sidebar slides open or closed (``ContentAreaMotionHosting``).
    final class SlidingWindow: NSWindow, ContentAreaMotionHosting {
        var isContentAreaInMotion = false
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let tree: SplitNode

        init(_ tree: SplitNode, reduceMotion: Bool = false, sliding: Bool = false) {
            self.tree = tree
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            window = sliding
                ? SlidingWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
                : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        /// Narrows the content area by `step` points `frames` times, as a sidebar sliding
        /// open does: one layout pass per display frame, each at a real size.
        func narrow(by step: CGFloat, frames: Int) {
            var width = window.contentLayoutRect.width
            for _ in 1...frames {
                width -= step
                window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
                root.layoutSubtreeIfNeeded()
            }
        }

        func zoom(_ pane: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(pane)), zoomed: true)])
            root.syncWithModel()
        }

        func unzoom() {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        func probe(_ pane: PaneID) throws -> GridProbe { try #require(provider.probes[pane]) }

        /// Steps 120 Hz frames until nothing moves (at most 2 s).
        func settle() {
            for _ in 1...240 where root.advanceFrame(1.0 / 120) {}
        }

        func tearDown() { window.closeAfterTest() }
    }

    /// p1 p2 / p3 p4.
    static let grid2: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                         a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                         b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    /// p1 | p2.
    static let pair: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    /// The zoom's own turn reports no grid, and neither does a frame in which the dim comes over the other
    /// panes (the pane keeps its slot in them); the one frame that shows the zoom reports the zoomed pane's
    /// final grid; no frame after it reports another.
    @Test(arguments: ["p1", "p2", "p3", "p4"])
    func aZoomInA2x2ReportsTheTerminalGridOnceInTheFrameThatShowsIt(pane: String) throws {
        let screen = Screen(Self.grid2)
        defer { screen.tearDown() }
        let probe = try screen.probe(PaneID(pane))
        let before = probe.reports.count
        screen.zoom(PaneID(pane))
        #expect(probe.reports.count == before, "the zoom's own turn reported a grid: it goes with the frame that shows the zoom")
        // Each frame of the dim asks for the next one; the frame that shows the zoom asks for no more.
        var waited = 0
        while waited < 40, screen.root.advanceFrame(1.0 / 120) {
            waited += 1
            #expect(probe.reports.count == before, "frame \(waited), before the one that shows the zoom, reported a grid")
        }
        #expect(waited < 40, "the zoom did not show in the 40 frames after its key")
        let shown = Array(probe.reports.dropFirst(before))
        #expect(shown.count == 1, "the frame that shows a zoom reported \(shown.count) grids")
        #expect(shown.last == probe.grid, "the grid reported is not the zoomed pane's final grid")
        screen.settle()
        #expect(probe.reports.count == before + 1, "a frame after the zoom showed reported \(probe.reports.count - before - 1) more grids")
    }

    /// An unzoom reports the pane's grid once, with the frame that shows it. A zoom taken back in its own
    /// turn (Cmd-Shift-Enter twice before a frame) never shows: the pane keeps its slot and its size, and
    /// the PTY is never resized.
    @Test func anUnzoomReportsOnceAndAZoomTakenBackBeforeItShowsReportsNothing() throws {
        let screen = Screen(Self.pair)
        defer { screen.tearDown() }
        let probe = try screen.probe("p2")
        screen.zoom("p2")
        screen.settle()
        let zoomed = probe.reports.count
        screen.unzoom()
        #expect(probe.reports.count == zoomed, "the unzoom's own turn reported a grid: it goes with the frame that shows the unzoom")
        screen.settle()
        #expect(probe.reports.count - zoomed == 1, "one unzoom reported \(probe.reports.count - zoomed) grids")
        #expect(probe.reports.last == probe.grid)

        // Zoom, then Cmd-Shift-Enter again in the same turn: no frame shows the zoom, the pane stays in the
        // slot whose grid the owner already has, so the PTY is never resized.
        let rest = probe.reports.count
        screen.zoom("p2")
        screen.unzoom()
        screen.settle()
        #expect(probe.reports.count == rest, "a zoom taken back before it showed resized the PTY \(probe.reports.count - rest) times")
    }

    /// Side panes lagged when the sidebar opened and closed: the sidebar's width animation moves the
    /// content edge on every display frame, so every pane beside it resizes on every frame even
    /// though no pane is on a layout spring of its own. The window says the content area is in
    /// motion (``ContentAreaMotionHosting``) and the terminals hold their grid until it lands, as
    /// a terminal in a pane on a layout spring does.
    @Test func aSidebarSlideReportsOneGridPerTerminalAtTheLandingNotOnEveryFrame() throws {
        let screen = Screen(Self.pair, sliding: true)
        defer { screen.tearDown() }
        let window = try #require(screen.window as? SlidingWindow)
        let probe = try screen.probe("p1")
        let before = probe.reports.count

        window.isContentAreaInMotion = true
        screen.narrow(by: 12, frames: 20)
        #expect(probe.reports.count == before,
                "a slide reported \(probe.reports.count - before) grids: a PTY resize and shell redraw per frame")

        window.isContentAreaInMotion = false
        screen.root.notifyPaneMotionSettled()
        let reports = Array(probe.reports.dropFirst(before))
        #expect(reports.count == 1, "the landing reported \(reports.count) grids")
        #expect(reports.last == probe.grid, "the grid reported is not the pane's grid at the landing")
        #expect(probe.settles >= 1, "the terminal never heard the slide land")
    }

    /// A resize with no sidebar motion still reaches the PTY on the frame it happens: the hold
    /// is for the slide, not for every resize. This is what goes red if the window's conformance
    /// stops matching the shell window's root view.
    @Test func aResizeOutsideASlideStillReportsItsGridAtOnce() throws {
        let screen = Screen(Self.pair, sliding: true)
        defer { screen.tearDown() }
        let probe = try screen.probe("p1")
        let before = probe.reports.count
        // 48 points off the window is 24 off each pane of the pair: three columns a frame,
        // so every step is a new grid and none is dropped as unchanged.
        screen.narrow(by: 48, frames: 3)
        #expect(probe.reports.count - before == 3,
                "a plain resize reported \(probe.reports.count - before) grids instead of three: the hold leaked")
    }

    @Test func reduceMotionZoomReportsOnceInTheSameFrame() throws {
        let screen = Screen(Self.grid2, reduceMotion: true)
        defer { screen.tearDown() }
        let probe = try screen.probe("p4")
        let before = probe.reports.count
        screen.zoom("p4")
        // The snap shows at the next frame tick, its terminal drawn at the new size (#37330): one frame.
        _ = screen.root.advanceFrame(1.0 / 120)
        #expect(probe.reports.count - before == 1, "Reduce Motion zoom did not report its grid at once")
        #expect(probe.reports.last == probe.grid)
    }
}
