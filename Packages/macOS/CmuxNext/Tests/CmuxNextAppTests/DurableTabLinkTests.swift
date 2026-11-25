import CmuxNextDaemonService
import Testing

/// A `cmux://tab/tab_…` link to a closed tab reopens it by its id
/// (plans/cmux-next/durable-links-DESIGN.md): every connected daemon is asked
/// in order, local first; the first that holds the tab in its closed history
/// reopens it, and the link reveals that same id. None holding it is the gone
/// refusal; any other failure stops the walk and is reported.
@MainActor
struct DurableTabLinkTests {
    private struct Failure: Error {}

    @Test func theFirstDaemonThatHoldsTheClosedTabReopensIt() async {
        var asked: [String] = []
        let outcome = await ClosedLinkSearch(daemons: ["local", "mini", "cloud"]).reopen { daemon in
            asked.append(daemon)
            return daemon == "mini" ? .reopened : .notInHistory
        }
        #expect(outcome == .reopened(on: "mini"))
        #expect(asked == ["local", "mini"], "a daemon after the one that reopened it is never asked")
    }

    @Test func aTabNoDaemonHoldsIsGone() async {
        let outcome = await ClosedLinkSearch(daemons: ["local", "mini"]).reopen { _ in .notInHistory }
        #expect(outcome == .gone)
    }

    @Test func noConnectedDaemonIsGone() async {
        let outcome = await ClosedLinkSearch(daemons: [String]()).reopen { _ in .reopened }
        #expect(outcome == .gone)
    }

    @Test func aFailureStopsTheWalkAndIsReported() async {
        var asked: [String] = []
        let outcome = await ClosedLinkSearch(daemons: ["local", "mini"]).reopen { daemon in
            asked.append(daemon)
            throw Failure()
        }
        #expect(outcome == .failed(on: "local"))
        #expect(asked == ["local"])
    }
}
