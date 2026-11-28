@testable import CmuxNextBrowser
import Testing

/// The browser pane's launch marks (`browser_pane.first_paint`, `browser_pane.input_ready`): only a front page a person
/// opened counts. Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our [...]
/// agent pane."
@Suite struct CEFLaunchMarksTests {
    @Test func onlyAFrontPageAPersonOpenedCounts() {
        #expect(CEFLaunchMarks.counts(agentDriven: false, inFront: true, blank: false))
        #expect(!CEFLaunchMarks.counts(agentDriven: true, inFront: true, blank: false))
        #expect(!CEFLaunchMarks.counts(agentDriven: false, inFront: false, blank: false))
        #expect(!CEFLaunchMarks.counts(agentDriven: false, inFront: true, blank: true))
    }

    @Test func theMarksAreTheStageTablesNames() {
        #expect(CEFLaunchMarks.firstPaint == "browser_pane.first_paint")
        #expect(CEFLaunchMarks.inputReady == "browser_pane.input_ready")
    }
}
