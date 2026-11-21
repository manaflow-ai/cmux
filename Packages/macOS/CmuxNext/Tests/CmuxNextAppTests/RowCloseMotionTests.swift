import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Closing the bottom row of a column whose rows overflow: the close and the shift it needs are one commit. The
/// frame that shows the close shows the row that stays at its place, with the column's camera at rest at the new end
/// of its rows. No frame shows that row on its way there, beside the ground of the row that left.
@MainActor
@Suite(.closesItsWindows)
struct RowCloseMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func closingTheFocusedBottomRowShowsTheMiddleRowAtItsPlaceInTheSameFrame() throws {
        let provider = Panes()
        let kept: SplitNode = .split("upper", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("middle"))
        let tree: SplitNode = .split("lower", axis: .vertical, ratio: 0.5, a: kept, b: .leaf("bottom"))
        let rows = [LayoutRow(id: "r1", height: 750, root: .leaf("top")),
                    LayoutRow(id: "r2", height: 750, root: .leaf("middle")),
                    LayoutRow(id: "r3", height: 750, root: .leaf("bottom"))]
        let column = LayoutColumn(id: "c", width: 1, root: tree, rows: rows)
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))],
                                activeScreenID: "s", focusedPane: "bottom")
        model.followsDesignMetrics = false
        model.baseStyle.columnGap = 0
        model.rowsEnabledOverride = true
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // The test is the clock: the display link never ticks.
        root.driver.isManual = true
        for _ in 0..<240 { if !root.advanceFrame(1.0 / 120) { break } }
        let screen = try #require(root.screenViews["s"])
        #expect(abs(screen.rowOffset(of: "middle") - 1000) < 0.5)
        #expect(!screen.hasMotion)
        let before = try #require(screen.displayedFrame(of: "middle"))

        let remaining = LayoutColumn(id: "c", width: 1, root: kept, rows: Array(rows.prefix(2)))
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([remaining]))])
        model.focus("middle")
        root.syncWithModel()
        // What shows: the host's frame in the close's own turn (the close resizes no pane, so it waits for no tick).
        let shown = try #require(root.context.hosts["middle"]?.frame)
        #expect(!screen.rowsMoving && !screen.hasMotion, "the close left the column's camera or a pane on a spring")
        #expect(abs(screen.rowOffset(of: "middle") - 400) < 0.5, "the column's camera is not at the new end of its rows: \(screen.rowOffset(of: "middle"))")
        #expect(abs(shown.minY - before.minY) > 100, "the middle row did not move into view with the close: \(before) -> \(shown)")
        #expect(screen.bounds.insetBy(dx: -0.5, dy: -0.5).contains(shown), "the middle row is not on screen in the frame that shows the close: \(shown)")
        #expect(shown == screen.displayedFrame(of: "middle"), "the middle row's host is not where the layout puts it: \(shown)")
        #expect(!root.advanceFrame(1.0 / 120), "a close that showed asks for frames")
        #expect(root.context.hosts["middle"]?.frame == shown, "the middle row moved after the frame that showed the close")
        #expect(screen.visiblePanes().contains("middle"))
    }
}
