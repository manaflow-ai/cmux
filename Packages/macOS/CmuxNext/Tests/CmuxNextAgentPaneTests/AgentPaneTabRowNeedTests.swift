import CmuxNextDesign
import CoreGraphics
import Foundation
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

    /// After a relaunch the chat is under the strip from its first layout: a row that waited for the page's first
    /// report laid it below the strip and then under it, a 34 px drop of the composer after every launch.
    @Test func aRelaunchedRowStartsWhereTheLastLaunchLeftIt() throws {
        let suite = "AgentPaneTabRowKept-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AgentPaneTabRow(defaults: defaults).sharedWidth(zoom: 1) == nil)
        AgentPaneTabRow(defaults: defaults).report(width: 180)
        let relaunched = AgentPaneTabRow(defaults: defaults)
        #expect(relaunched.sharedWidth(zoom: 1) == 180)
        #expect(relaunched.sharedNeed(zoom: 1) == 180)
        relaunched.report(width: 0)
        #expect(relaunched.sharedWidth(zoom: 1) == nil)
    }

    @Test func toolsThatLeaveGiveTheRowBack() {
        let row = AgentPaneTabRow()
        row.report(width: 180)
        row.report(width: 0)
        #expect(row.sharedWidth(zoom: 1) == nil)
    }
}
