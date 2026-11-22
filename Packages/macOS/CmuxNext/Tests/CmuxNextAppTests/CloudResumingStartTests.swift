import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A start or attach on a machine that is resuming waits for it instead of refusing (prod, 2026-11-05: after
/// `cmux cloud resume-machine`, `cloud start-chat` refused at once with "This machine is resuming. Try again once it
/// is running.", and the same start worked in 12 s once the machine ran). The wait is bounded by the start's own
/// connect wait; a pause or delete still refuses at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudResumingStartTests {
    static func resuming() -> (services: AppServices, session: CloudMachineSession) {
        let f = CloudIdlePauseTests.pausedMachine(reason: .idle)
        // Resume Machine runs: the record still says paused, the change says starting.
        f.session.machine.pendingChange = .starting
        return (f.services, f.session)
    }

    static func invocation(_ session: CloudMachineSession) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), arguments: [:], origin: .cli)
    }

    /// The record read during the wait finds the machine running: the attach goes on. Before, it refused at once.
    @Test func anAttachToAResumingMachineWaitsUntilItRuns() async throws {
        let f = Self.resuming()
        let session = f.session
        defer { session.disconnect() }
        var reads = 0
        session.refresher = { [weak session] _ in
            reads += 1
            guard let session else { return }
            session.machine.status = .running
            session.machine.pendingChange = nil
        }
        try await CloudHandlers.attached(session, Self.invocation(session), within: .seconds(20))
        #expect(reads >= 1, "the wait read the record again")
        #expect(session.machine.shownStatus == .running)
    }

    /// A resume that is still running at the limit refuses as before.
    @Test func aResumeThatOutlastsTheWaitStillRefuses() async {
        let f = Self.resuming()
        defer { f.session.disconnect() }
        f.session.refresher = { _ in }
        await #expect(throws: ActionFailure.self) {
            try await CloudHandlers.requireAttachableState(f.session, waitingOutResume: .milliseconds(300))
        }
    }

    /// A machine that is pausing or being deleted is no resume to wait out: it refuses at once.
    @Test func aPausingMachineRefusesWithoutWaiting() async {
        let f = Self.resuming()
        defer { f.session.disconnect() }
        f.session.refresher = { _ in Issue.record("a pausing machine is not waited for") }
        for change: CloudMachine.Status in [.pausing, .deleting] {
            f.session.machine.pendingChange = change
            let clock = ContinuousClock(), began = clock.now
            await #expect(throws: ActionFailure.self) {
                try await CloudHandlers.requireAttachableState(f.session, waitingOutResume: .seconds(30))
            }
            #expect(began.duration(to: clock.now) < .seconds(5))
        }
    }
}
