import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTerminalGeometry
import Testing

/// Cmd-Shift-Enter was laggy and buggy on terminals (Lawrence 2026-10-20): the zooming pane is laid
/// out live at its spring rect on every frame, and every new size reported a new grid to the PTY
/// owner, so one zoom made ~30 PTY resizes, shell redraws and owner reflows, and announcements
/// landing frames behind the view made the text jump. The pane still moves live (its terminal
/// draws the reflow preview at every size); the grid goes to the owner once, when the spring lands.
@MainActor
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

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let tree: SplitNode

        init(_ tree: SplitNode, reduceMotion: Bool = false) {
            self.tree = tree
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
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
    }

    /// p1 p2 / p3 p4.
    static let grid2: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                         a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                         b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    /// p1 | p2.
    static let pair: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    @Test(arguments: ["p1", "p2", "p3", "p4"])
    func aZoomInA2x2ReportsTheTerminalGridOnceWhenItLandsNotOnEveryFrame(pane: String) throws {
        let screen = Screen(Self.grid2)
        let probe = try screen.probe(PaneID(pane))
        let before = probe.reports.count
        screen.zoom(PaneID(pane))
        screen.settle()
        let reports = Array(probe.reports.dropFirst(before))
        #expect(reports.count == 1, "one zoom reported \(reports.count) grids: a PTY resize per frame")
        #expect(reports.last == probe.grid, "the grid reported is not the zoomed pane's final grid")
        #expect(probe.settles >= 1, "the terminal never heard the zoom land")
    }

    @Test func anUnzoomReportsOnceAndAZoomInterruptedBackToItsSlotReportsNothing() throws {
        let screen = Screen(Self.pair)
        let probe = try screen.probe("p2")
        screen.zoom("p2")
        screen.settle()
        let zoomed = probe.reports.count
        screen.unzoom()
        screen.settle()
        #expect(probe.reports.count - zoomed == 1, "one unzoom reported \(probe.reports.count - zoomed) grids")
        #expect(probe.reports.last == probe.grid)

        // Zoom, then Cmd-Shift-Enter again a few frames in: it springs back to the slot whose grid the
        // owner already has, so the PTY is never resized.
        let rest = probe.reports.count
        screen.zoom("p2")
        for _ in 1...4 { screen.root.advanceFrame(1.0 / 120) }
        screen.unzoom()
        screen.settle()
        #expect(probe.reports.count == rest, "an interrupted zoom resized the PTY \(probe.reports.count - rest) times")
    }

    @Test func reduceMotionZoomReportsOnceInTheSameFrame() throws {
        let screen = Screen(Self.grid2, reduceMotion: true)
        let probe = try screen.probe("p4")
        let before = probe.reports.count
        screen.zoom("p4")
        #expect(probe.reports.count - before == 1, "Reduce Motion zoom did not report its grid at once")
        #expect(probe.reports.last == probe.grid)
    }
}
