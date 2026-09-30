import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import Testing

/// Dogfood nxdog12: "need proper left alignment here". In a pane, the tab
/// icon, the terminal's first text column and the browser toolbar line up
/// on one grid measured from the pane's content edge (the rounded border's
/// left side, shared by the tab strip), in both densities.
@MainActor
@Suite(.serialized)
struct PaneAlignmentTests {
    /// The first tab's pill and icon x in a pane of `width` (pane-local).
    private func firstTab(width: CGFloat) -> (pill: CGFloat, icon: CGFloat) {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "~")], selectedID: TabID("t0"))
        let pane = PaneContentView(stripModel: model)
        pane.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        pane.layoutSubtreeIfNeeded()
        pane.stripView.sync(fromModel: true)
        pane.stripView.layoutSubtreeIfNeeded()
        pane.stripView.relayout(animated: false)
        let strip = pane.stripView
        let cell = strip.cells[TabID("t0")]!
        cell.layoutLayers()
        let pill = strip.tabsClip.convert(cell.frame.insetBy(dx: strip.metrics.tabBackgroundInset, dy: 0), to: pane).minX
        let icon = strip.tabsClip.convert(CGPoint(x: cell.frame.minX + cell.iconLayer.frame.minX, y: 0), to: pane).x
        return (pill, icon)
    }

    @Test(arguments: Density.allCases)
    func tabIconTerminalColumnAndToolbarShareTheGrid(density: Density) {
        let saved = DesignSettings.shared.density
        DesignSettings.shared.density = density
        defer { DesignSettings.shared.density = saved }
        let tab = firstTab(width: 600)
        #expect(tab.pill == Metrics.paneChromeInset)
        #expect(tab.icon == Metrics.paneContentInset)
        // The terminal host sits at the pane's content edge (x 0).
        let surface = TerminalHostView.surfaceFrame(in: CGRect(x: 0, y: 0, width: 600, height: 400), contentInset: Metrics.paneContentInset)
        #expect(surface.minX + TerminalHostView.ghosttyDefaultPaddingX == tab.icon)
        #expect(surface.maxX == 600 - surface.minX)
        // The browser toolbar's first button shape starts on the pills' line.
        #expect(BrowserChromeView.toolbarMetrics.inset == tab.pill)
    }

    @Test func aNarrowHostKeepsItsWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 20, height: 40)
        #expect(TerminalHostView.surfaceFrame(in: bounds, contentInset: 10) == bounds)
        #expect(TerminalHostView.surfaceFrame(in: CGRect(x: 0, y: 0, width: 400, height: 40), contentInset: 1).minX == 0)
    }
}
