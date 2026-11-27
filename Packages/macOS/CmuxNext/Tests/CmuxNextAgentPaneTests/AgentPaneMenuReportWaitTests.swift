import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Chromium agent page's right-click waits for the page's report of what is under the pointer
/// (``AgentPaneMenuReportWait``): a report that came first counts once, a report that comes later
/// ends the wait, and a page that sends none still gets its menu after the limit.
@MainActor
struct AgentPaneMenuReportWaitTests {
    @Test func aReportThatCameFirstCountsForTheNextMenuOnly() async {
        let wait = AgentPaneMenuReportWait(limit: .seconds(30))
        wait.reported()
        await wait.untilReported()
        // Used up: the next menu waits again, until its own report.
        var ended = false
        let menu = Task { @MainActor in
            await wait.untilReported()
            ended = true
        }
        await Task.yield()
        #expect(!ended)
        wait.reported()
        await menu.value
        #expect(ended)
    }

    @Test func aPageThatSendsNoReportStillGetsItsMenu() async {
        let wait = AgentPaneMenuReportWait(limit: .milliseconds(1))
        await wait.untilReported()
    }

    @Test func aStaleReportDoesNotCount() async {
        let wait = AgentPaneMenuReportWait(limit: .milliseconds(1), freshness: .zero)
        wait.reported()
        let started = ContinuousClock.now
        await wait.untilReported()
        // It waited for the limit instead of taking the old report (fresh only within zero seconds).
        #expect(ContinuousClock.now - started >= .milliseconds(1))
    }
}
