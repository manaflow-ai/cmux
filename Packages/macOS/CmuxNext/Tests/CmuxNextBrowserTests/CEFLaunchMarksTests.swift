@testable import CmuxNextBrowser
import Foundation
import Testing

/// The browser pane's launch marks (`browser_pane.first_paint`, `browser_pane.input_ready`): once per launch each, a
/// mark made before the App installed its receiver arrives with its own time, and only a front page a person opened
/// counts. Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our motherfucking
/// agent pane."
@MainActor @Suite(.serialized) struct CEFLaunchMarksTests {
    @Test func eachMarkComesOncePerLaunchAndEarlyMarksKeepTheirTime() {
        CEFLaunchMarks.resetForTests()
        defer { CEFLaunchMarks.resetForTests() }
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        CEFLaunchMarks.mark(CEFLaunchMarks.firstPaint, at: early)
        var got: [(String, Date)] = []
        CEFLaunchMarks.install { got.append(($0, $1)) }
        #expect(got.map(\.0) == [CEFLaunchMarks.firstPaint])
        #expect(got.first?.1 == early)
        CEFLaunchMarks.mark(CEFLaunchMarks.firstPaint)
        CEFLaunchMarks.mark(CEFLaunchMarks.inputReady)
        CEFLaunchMarks.mark(CEFLaunchMarks.inputReady)
        #expect(got.map(\.0) == [CEFLaunchMarks.firstPaint, CEFLaunchMarks.inputReady])
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
