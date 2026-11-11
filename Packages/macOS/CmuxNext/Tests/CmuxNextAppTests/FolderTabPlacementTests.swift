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

    /// Anything under the strip that covers the window's shade (the pane's own picture or cover, the
    /// strip's own `appearance.surfaces.tabBar` fill) makes the strip draw its own band (Codex at 8d339374).
    @Test func aStripOverItsPanesBackdropOrItsOwnFillCoversTheShade() {
        let (pane, window) = strip(joinsContent: true)
        defer { window.close() }
        #expect(!pane.coversWindowShade)
        pane.sitsOnPaneBackdrop = true
        #expect((pane as any TabStripCorner).coversWindowShade)
        pane.sitsOnPaneBackdrop = false
        pane.layer?.backgroundColor = CGColor(srgbRed: 0.9, green: 0.9, blue: 0.95, alpha: 1)
        #expect(pane.coversWindowShade)
    }

    /// The one rule (TabStripView.folderSeen) over the matrix: translucent or opaque window x a tab bar
    /// fill x a pane picture x tabs on top or bottom. Each case is what reaches the rule: a bottom strip
    /// runs into nothing; a fill or a pane picture gives the strip its band; otherwise the frame's hole.
    /// The pill goes only when the folder is cut out of a shade that shows and reads.
    @Test(arguments: [false, true], [false, true])
    func thePillGoesOnlyWhenTheFolderIsSeen(translucent: Bool, top: Bool) {
        for covered in [false, true] { // a tab bar fill or a perPane picture under the strip
            for framed in [true, false] { // the frame drawn (a top row), or hidden
                let band: CGFloat = covered || !framed ? (top ? 0.045 : 0) : 0
                let hole = top && framed && !covered
                for reads in [true, false] {
                    let seen = TabStripView.folderSeen(runsIntoCard: top, hasFolder: top, band: band, hole: hole) { reads }
                    let expected = top && reads && (band > 0 || hole)
                    #expect(seen == expected, "translucent \(translucent) top \(top) covered \(covered) framed \(framed) reads \(reads)")
                    if !top { #expect(!seen, "bottom tabs keep the pill") }
                    if !reads { #expect(!seen, "a folder that does not read keeps the pill") }
                }
            }
        }
    }

    @Test func noShadeNeverReads() {
        #expect(!Palette.folderReads(over: nil, shade: 0))
    }
}
