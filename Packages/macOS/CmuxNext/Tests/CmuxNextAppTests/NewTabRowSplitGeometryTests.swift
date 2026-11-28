import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.closesItsWindows)
struct NewTabRowSplitGeometryTests {
    @Test func dividerPrefetchWrapsTheWholeCompositeFirstSide() throws {
        let first = SplitNode.split("nested", axis: .vertical, ratio: 0.35, a: .leaf("a"), b: .leaf("b"))
        let tree = SplitNode.split("divider", axis: .horizontal, ratio: 0.7, a: first, b: .leaf("c"))
        let window = DropPreviewLandingParityTests.Window(tree)
        defer { window.window.closeAfterTest() }
        let view = try #require(window.root.screenViews["s"])
        let ratio = DividerInsertPlan.dividerRatio
        let predicted = try #require(view.newDividerPaneSize(splitting: "divider", ratio: ratio))
        let landed = SplitNode.split("divider", axis: .horizontal, ratio: ratio,
                                    a: .split("created", axis: .horizontal, ratio: 0.5, a: first, b: .leaf("new")), b: .leaf("c"))
        let geometry = ScreenGeometry.compute(.splits(landed), viewport: view.bounds.size, style: view.context.style,
                                              scale: window.window.backingScaleFactor)
        let cell = try #require(geometry.panes["new"])
        #expect(predicted == PaneChromeGeometry.contentRect(forCell: cell, style: view.context.style).size)
    }

    @Test func splitPrefetchKeepsTheContainingRowsHeight() throws {
        let initial = KeyboardResizeRowsTests.start
        let model = LayoutModel(screens: [.init(id: "s", name: "s", layout: initial)], activeScreenID: "s", focusedPane: "p1")
        model.rowsEnabledOverride = true
        model.splitSizingOverride = .even
        let provider = DropPreviewLandingParityTests.Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        let view = try #require(root.screenViews["s"])
        for zone in [PaneDropZone.right, .bottom] {
            let size = try #require(view.newSplitPaneSize(splitting: "p1", zone: zone))
            guard case var .columns(columns) = initial else { return }
            columns[0].rows[0].root = .split("created", axis: zone == .right ? .horizontal : .vertical,
                                            ratio: 0.5, a: .leaf("p1"), b: .leaf("new"))
            let landed = ScreenGeometry.compute(.columns(columns), viewport: view.bounds.size, style: view.context.style,
                                                scale: window.backingScaleFactor)
            let cell = try #require(landed.panes["new"])
            #expect(size == PaneChromeGeometry.contentRect(forCell: cell, style: view.context.style).size)
        }
    }
}
