import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// Settings > Updates' acpmux daemon row: the running build, and whether it is the bundled
/// build, restarting on it, another build the app keeps, or not running.
struct AcpmuxDaemonSummaryTests {
    typealias Summary = AcpmuxDaemonSummary

    @Test func theBundledBuildIsUpToDate() {
        let summary = Summary(answered: true, running: "abc", bundled: "abc", restarting: false)
        #expect(summary == Summary(build: "abc", state: .upToDate))
        #expect(summary.text.contains("abc"))
    }

    @Test func anotherBuildOrAHandoffIsRestarting() {
        let stale = Summary(answered: true, running: "old", bundled: "new", restarting: false)
        #expect(stale == Summary(build: "old", state: .restarting))
        #expect(stale.text.contains("old"))
        // Stopped by a handoff, the bundled daemon not up yet: its build is the bundled one.
        #expect(Summary(answered: false, running: nil, bundled: "new", restarting: true)
            == Summary(build: "new", state: .restarting))
    }

    /// A replaced bundle's daemon of the bundled build is restarted at the next lookup too.
    @Test func aReplacedBundleIsRestarting() {
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, replaced: true)
            == Summary(build: "abc", state: .restarting))
    }

    /// Another build no lookup hands off (a memory store without agent hosts, a handoff that
    /// could not stop it) never says it restarts.
    @Test func anotherBuildNoLookupHandsOffIsNotTheAppsBuild() {
        let kept = Summary(answered: true, running: "old", bundled: "new", restarting: false, handsOff: false)
        #expect(kept == Summary(build: "old", state: .otherBuild))
        #expect(kept.text.contains("old"))
        // The same build stays up to date whatever a handoff would do.
        #expect(Summary(answered: true, running: "abc", bundled: "abc", restarting: false, handsOff: false).state == .upToDate)
    }

    @Test func noAnswerIsNotRunning() {
        #expect(Summary(answered: false, running: nil, bundled: "new", restarting: false).state == .notRunning)
    }

    @Test func aBuildEitherSideDoesNotKnowIsUpToDate() {
        #expect(Summary(answered: true, running: "abc", bundled: nil, restarting: false) == Summary(build: "abc", state: .upToDate))
        #expect(Summary(answered: true, running: nil, bundled: "abc", restarting: false).state == .upToDate)
    }

    /// Leo: the team's daemons are hardly ever idle, so a stale acpmux is replaced at once.
    @Test func theQuietWaitIsOffByDefault() {
        #expect(AgentPaneTunables.replaceStaleAcpmuxWhenQuiet.defaultValue == false)
    }
}
