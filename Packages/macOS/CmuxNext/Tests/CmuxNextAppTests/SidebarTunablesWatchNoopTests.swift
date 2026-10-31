import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// `SidebarTunablesWatch.changed()` redrew and re-laid-out every live row in the process each time it ran,
/// even when no tunable had changed. One tunable set runs it up to three times (the test's own call plus
/// both observations, which each read `sidebar.agentMark`), each pass over every row of every open list, so
/// whole-process `swift test` runs stalled on the main thread there until the 300 s watchdog killed them
/// (PR #27961 run 41059291481 attempt 2, and five other branches' runs the same day).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarTunablesWatchNoopTests {
    /// A pass that finds the rows already drawn with the current values touches no row.
    @Test func aPassWithNoTunableChangeLeavesTheRowsAlone() throws {
        let (_, sidebar, window) = SidebarTabGroupControlsTests.sidebar()
        defer { window.close() }
        window.orderFrontRegardless()
        sidebar.renderNow()
        let row = try #require(sidebar.list.rowViews[.workspace(SidebarTabGroupControlsTests.other)] as? WorkspaceRowView)
        // One synchronous turn: no other test can set a tunable between these calls.
        SidebarTunablesWatch.shared.changed()
        row.layoutSubtreeIfNeeded()
        #expect(!row.needsLayout)
        SidebarTunablesWatch.shared.changed()
        #expect(!row.needsLayout, "a pass with no tunable change laid the row out again")
    }

    /// A real change still reaches the live rows, and the pass after it, with nothing new, does not.
    @Test func aRealChangeStillRedrawsTheRowsOnce() throws {
        try SidebarTabGroupControlsTests.withCloseSpot(.end) {
            let (_, sidebar, window) = SidebarTabGroupControlsTests.sidebar()
            defer { window.close() }
            window.orderFrontRegardless()
            sidebar.renderNow()
            let row = try #require(sidebar.list.rowViews[.workspace(SidebarTabGroupControlsTests.other)] as? WorkspaceRowView)
            SidebarTunablesWatch.shared.changed()
            row.layoutSubtreeIfNeeded()
            try SidebarTabGroupControlsTests.withCloseSpot(.middle) {
                SidebarTunablesWatch.shared.changed()
                #expect(row.needsLayout, "a changed close spot did not reach the live row")
                row.layoutSubtreeIfNeeded()
                SidebarTunablesWatch.shared.changed()
                #expect(!row.needsLayout, "the pass after the change laid the row out again")
            }
            SidebarTunablesWatch.shared.changed()
        }
    }
}
