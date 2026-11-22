@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing

/// The browser pane's launch marks (`browser_pane.first_paint`, `browser_pane.input_ready`): once per launch each, a
/// mark made before the App installed its receiver arrives with its own time, and only a front page a person opened
/// counts. Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our motherfucking
/// agent pane."
@Suite struct CEFLaunchMarksTests {
    @Test func eachMarkComesOncePerLaunchAndEarlyMarksKeepTheirTime() {
        let marks = CEFLaunchMarks()
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        marks.mark(CEFLaunchMarks.firstPaint, at: early)
        let got = Mutex<[(String, Date)]>([])
        marks.install { name, date in got.withLock { $0.append((name, date)) } }
        #expect(got.withLock { $0.map(\.0) } == [CEFLaunchMarks.firstPaint])
        #expect(got.withLock { $0.first?.1 } == early)
        marks.mark(CEFLaunchMarks.firstPaint)
        marks.mark(CEFLaunchMarks.inputReady)
        marks.mark(CEFLaunchMarks.inputReady)
        #expect(got.withLock { $0.map(\.0) } == [CEFLaunchMarks.firstPaint, CEFLaunchMarks.inputReady])
    }

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
