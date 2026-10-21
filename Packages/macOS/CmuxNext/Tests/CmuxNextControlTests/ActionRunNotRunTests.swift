import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// Answers `openBrowser` with a fixed outcome and, optionally, work that
/// fails the way a handler's background work does.
final class RefusingExecutor: ControlActionExecutor {
    let outcome: ControlActionOutcome
    let failure: ActionWorkFailure?

    init(_ outcome: ControlActionOutcome, failure: ActionWorkFailure? = nil) {
        self.outcome = outcome
        self.failure = failure
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { outcome }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        guard let failure else { return ControlActionRun(outcome: outcome) }
        let work: ActionWork = Task { failure }
        return ControlActionRun(outcome: outcome, work: [work])
    }
}

/// `action.run` marks a refusal made before anything ran with `data.not_run`,
/// so the CLI can say nothing applied (no "may still apply" retry note). A
/// refusal that comes from the action's work, which may have applied part of
/// the change (a group created, a send still resending), carries no mark.
@Suite(.timeLimit(.minutes(1))) struct ActionRunNotRunTests {
    private func run(_ executor: RefusingExecutor, action: String = "openBrowser") async -> ControlError? {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        let reply = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": .string(action), "idempotency_key": "k-1",
        ]))
        guard case .failure(let error) = reply else {
            Issue.record("expected a refusal, got \(reply)")
            return nil
        }
        return error
    }

    @Test func anUnknownActionIsNotRun() async {
        let error = await run(RefusingExecutor(.ran), action: "workspace.new")
        #expect(error?.code == "not_found")
        #expect(error?.data?["not_run"] == true)
    }

    @Test func aHandlerRefusalWithNoWorkIsNotRun() async {
        let error = await run(RefusingExecutor(.refused("not enough room to split this pane")))
        #expect(error?.code == "unavailable")
        #expect(error?.data?["not_run"] == true)
        #expect(error?.data?["reason"] == "not enough room to split this pane")
    }

    @Test func aRefusalFromTheWorkIsNotMarked() async {
        let failure = ActionWorkFailure(refusal: .unavailable, reason: "the group was made but its replies were not set")
        let error = await run(RefusingExecutor(.ran, failure: failure))
        #expect(error?.code == "unavailable")
        #expect(error?.data?["not_run"] == nil)
    }

    @Test func aHandlerRefusalAfterItStartedWorkIsNotMarked() async {
        let failure = ActionWorkFailure("the reopened window did not show")
        let error = await run(RefusingExecutor(.refused("no window"), failure: failure))
        #expect(error?.code == "unavailable")
        #expect(error?.data?["not_run"] == nil)
    }
}
