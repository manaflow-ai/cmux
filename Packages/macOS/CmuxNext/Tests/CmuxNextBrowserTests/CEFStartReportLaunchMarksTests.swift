@testable import CmuxNextBrowser
import Testing

/// The first Chromium page's engine start as launch marks (CMUX-571): `cef.initialize_start` and
/// `cef.ready` sit where `CefInitialize` ran, as offsets from the caller's now, so a relaunch's marks
/// show how much of the restored chat's wait was Chromium's start.
@Suite struct CEFStartReportLaunchMarksTests {
    @Test func marksWhereInitializeRanAndReturned() {
        let report = CEFStartReport(state: "ready", preloaded: false, trigger: "tab", loadDuration: .milliseconds(90),
                                    initializeDuration: .milliseconds(150), readyAfterLaunch: 0.9)
        let marks = report.launchMarks(now: 1.2)
        #expect(marks.map(\.name) == ["cef.initialize_start", "cef.ready"])
        #expect(abs(marks[0].offset - -0.45) < 1e-9)
        #expect(abs(marks[1].offset - -0.3) < 1e-9)
    }

    @Test func noMarksBeforeChromiumIsReady() {
        let report = CEFStartReport(state: "loading", preloaded: true, trigger: nil, loadDuration: nil,
                                    initializeDuration: nil, readyAfterLaunch: nil)
        #expect(report.launchMarks(now: 1).isEmpty)
    }
}
