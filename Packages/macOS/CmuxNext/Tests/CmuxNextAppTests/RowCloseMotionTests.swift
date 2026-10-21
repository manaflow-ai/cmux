import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import Testing

/// Closing the bottom row keeps the surviving row where it showed while its camera springs back.
@MainActor
struct RowCloseMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func closingTheFocusedBottomRowSpringsTheMiddleRowIntoView() throws {
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
        let after = try #require(screen.displayedFrame(of: "middle"))
        #expect(abs(after.minY - before.minY) < 0.5, "closing a row jumped the surviving pane: \(before) -> \(after)")
        #expect(screen.rowsMoving)
        #expect(screen.hasMotion)
        for _ in 0..<240 { if !root.advanceFrame(1.0 / 120) { break } }

        let shown = try #require(screen.displayedFrame(of: "middle"))
        #expect(screen.bounds.insetBy(dx: -0.5, dy: -0.5).contains(shown), "the middle row rested off screen: \(shown)")
        #expect(abs(screen.rowOffset(of: "middle") - 400) < 0.5)
        #expect(!screen.hasMotion)
        #expect(screen.visiblePanes().contains("middle"))
    }
}
