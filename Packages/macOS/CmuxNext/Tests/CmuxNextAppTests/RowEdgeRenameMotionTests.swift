import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// A row edge keeps its spring when the daemon's column and rows replace an optimistic New Row's
/// under new ids (review 1 of PL-motion-core).
@MainActor
struct RowEdgeRenameMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A row edge springing (a New Row's height change) when the daemon's column and rows replace
    /// the stand-in's under new ids: the edge keeps its spring from where it shows. It went
    /// through the new-divider path and jumped to its rest in the middle of the motion.
    @Test func aRowEdgeKeepsItsSpringWhenItsRowsChangeID() throws {
        let tree: SplitNode = .split("rows", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("new"))
        func screen(column: ColumnID, rows ids: (RowID, RowID), top: Int) -> [LayoutScreen] {
            let rows = [LayoutRow(id: ids.0, height: top, root: .leaf("top")), LayoutRow(id: ids.1, height: 300, root: .leaf("new"))]
            return [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: column, width: 1, root: tree, rows: rows)]))]
        }
        let model = LayoutModel(screens: screen(column: "standin-column", rows: ("standin-top", "standin-new"), top: 700),
                                activeScreenID: "s", focusedPane: "new")
        model.followsDesignMetrics = false
        model.baseStyle.columnGap = 0
        model.rowsEnabledOverride = true
        model.acceptsRowOps = true
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for _ in 0..<240 { if !root.advanceFrame(1.0 / 120) { break } }
        let view = try #require(root.screenViews["s"])
        let standIn = DividerHandleView.Kind.rowEdge("standin-column", "standin-top")
        #expect(view.dividerFrames[standIn] != nil, "no row edge under the stand-in's top row")

        // The top row shrinks: its edge springs up. Heights summing to at most 1000 fill the column,
        // so nothing scrolls and the edge moves on screen (700 of 1000 to 400 of 700).
        model.apply(screens: screen(column: "standin-column", rows: ("standin-top", "standin-new"), top: 400))
        root.syncWithModel()
        _ = root.advanceFrame(1.0 / 120)
        _ = root.advanceFrame(1.0 / 120)
        let springing = try #require(view.dividerFrames[standIn])
        #expect(springing.rect != springing.targetRect, "the row edge is not springing")

        // The daemon's column and rows take the stand-in's over, at the same places.
        model.apply(screens: screen(column: "daemon-column", rows: ("daemon-top", "daemon-new"), top: 400))
        root.syncWithModel()
        let handed = try #require(view.dividerFrames[.rowEdge("daemon-column", "daemon-top")])
        #expect(view.dividerFrames[standIn] == nil)
        #expect(abs(handed.rect.minY - springing.rect.minY) < 1, "the row edge jumped at the handoff: \(springing.rect) -> \(handed.rect)")
        #expect(handed.rect != handed.targetRect, "the row edge landed at its rest in the middle of the motion")
    }
}
