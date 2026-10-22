import Testing
@testable import CmuxNextAgentPane

/// Settings > Updates' acpmux daemon row: the running build, and whether it is the bundled
/// build, restarting on it, or not running.
struct AcpmuxDaemonSummaryTests {
    typealias Summary = AcpmuxDaemonSummary

    @Test func theBundledBuildIsUpToDate() {
        let summary = Summary(answered: true, running: "abc", bundled: "abc", restarting: false)
        #expect(summary == Summary(build: "abc", state: .upToDate))
        #expect(summary.text == "abc (up to date)")
    }

    @Test func anotherBuildOrAHandoffIsRestarting() {
        let stale = Summary(answered: true, running: "old", bundled: "new", restarting: false)
        #expect(stale == Summary(build: "old", state: .restarting))
        #expect(stale.text == "old (restarting…)")
        // Stopped by a handoff, the bundled daemon not up yet: its build is the bundled one.
        #expect(Summary(answered: false, running: nil, bundled: "new", restarting: true)
            == Summary(build: "new", state: .restarting))
    }

    @Test func noAnswerIsNotRunning() {
        let summary = Summary(answered: false, running: nil, bundled: "new", restarting: false)
        #expect(summary.state == .notRunning)
        #expect(summary.text == "Not running")
    }

    @Test func aBuildEitherSideDoesNotKnowIsUpToDate() {
        #expect(Summary(answered: true, running: "abc", bundled: nil, restarting: false).text == "abc (up to date)")
        #expect(Summary(answered: true, running: nil, bundled: "abc", restarting: false).state == .upToDate)
    }
}
