import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextAgentPane

/// The chat page reports its tools' width while it is in the tab row and 0 when the row ends;
/// ``AgentPaneTabRow`` keeps the last positive width as the tools' need, which decides whether a
/// narrow pane offers the row at all (`PaneTabRowSharing.fitsTabRow`).
@MainActor
struct AgentPaneTabRowNeedTests {
    @Test func theLastPositiveWidthIsTheNeed() {
        let row = AgentPaneTabRow()
        #expect(row.neededWidth == 0)
        row.report(width: 180)
        #expect(row.neededWidth == 180)
        row.report(width: 0)
        #expect(row.toolsWidth == 0)
        #expect(row.neededWidth == 180)
        row.report(width: 210)
        #expect(row.neededWidth == 210)
    }

    /// The rolling summary takes only the row's leftover room: it is in the width the tabs give up, never in the
    /// need, so a pane split narrower than the width it was measured at still offers the row and the tools stay in it
    /// (Leo 2026-11-22: "the icons on the top right have gotten displaced due to putting things on a line").
    @Test func theNeedLeavesOutTheSummary() {
        let row = AgentPaneTabRow()
        row.report(width: 420, need: 140)
        #expect(row.toolsWidth == 420)
        #expect(row.neededWidth == 140)
        #expect(row.sharedNeed(zoom: 2) == 280)
        // An older page sends no need: its width is the need, as before; a need over the width is no more than it.
        row.report(width: 180)
        #expect(row.neededWidth == 180)
        row.report(width: 160, need: 900)
        #expect(row.neededWidth == 160)
    }

    @Test func aReloadedPageKeepsTheNeed() {
        let row = AgentPaneTabRow()
        row.report(width: 180)
        row.pageLoaded()
        #expect(row.toolsWidth == 0)
        #expect(row.neededWidth == 180)
    }
}

/// A page that loaded again keeps its tools' place in the row until it reports (Leo 2026-11-07, Trace-ID
/// ask-11b77f340e); a 0 it reports is its tools leaving the row.
@MainActor
struct AgentPaneTabRowReloadTests {
    @Test func aReloadedPageKeepsItsPlaceUntilItReports() {
        let row = AgentPaneTabRow()
        row.report(width: 180)
        row.pageLoaded()
        #expect(row.sharedWidth(zoom: 1) == 180)
        row.report(width: 0)
        #expect(row.sharedWidth(zoom: 1) == nil)
        #expect(row.sharedNeed(zoom: 1) == 180)
    }

    @Test func toolsThatLeaveGiveTheRowBack() {
        let row = AgentPaneTabRow()
        row.report(width: 180)
        row.report(width: 0)
        #expect(row.sharedWidth(zoom: 1) == nil)
    }
}
