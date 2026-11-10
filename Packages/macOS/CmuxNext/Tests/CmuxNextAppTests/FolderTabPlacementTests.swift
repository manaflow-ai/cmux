import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Where the folder tab goes (design/selected-is-foreground.md): a pane's strip joins the content
/// below it; the screen bar, at the bottom whatever the pane tabs' position, opens nothing under its
/// tabs and keeps the pill (Codex at b01bf4ed, F2). A strip over its pane's own backdrop says so, so
/// it draws the chrome's band itself (F1).
@MainActor @Suite(.cornerFlush(.goo)) struct FolderTabPlacementTests {
    private func strip(joinsContent: Bool) -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab1"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.joinsContent = joinsContent
        let height = TabStripView.preferredHeight + 12
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    @Test func aPaneStripJoinsTheContentAndTheScreenBarDoesNot() {
        guard DesignSettings.shared.tabBarPosition != .bottom else { return }
        let (pane, paneWindow) = strip(joinsContent: true)
        defer { paneWindow.close() }
        #expect((pane.cells[TabID("tab1")]?.cornerFoot ?? 0) > 0)
        let (bar, barWindow) = strip(joinsContent: false)
        defer { barWindow.close() }
        #expect(bar.cells[TabID("tab1")]?.cornerFoot == 0)
        #expect(bar.cells[TabID("tab1")]?.runsIntoCard == false)
    }

    @Test func aStripOverItsPanesBackdropSaysSo() {
        let (pane, window) = strip(joinsContent: true)
        defer { window.close() }
        #expect(!pane.sitsOnPaneBackdrop)
        pane.sitsOnPaneBackdrop = true
        #expect((pane as any TabStripCorner).sitsOnPaneBackdrop)
    }
}
