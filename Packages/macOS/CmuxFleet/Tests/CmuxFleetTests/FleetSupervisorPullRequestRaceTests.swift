import CmuxFleet
import Testing

@Suite("FleetSupervisor pull request races")
struct FleetSupervisorPullRequestRaceTests {
    @Test func openPullRequestAfterRetryBackoffAwaitsReviewAndCancelsBackoff() {
        let running = FleetTestSupport.task(state: .running, attempts: 1)
        let crashed = FleetSupervisor().reduce(
            task: running,
            signal: .pidExited(taskID: running.id, attempt: 1, at: FleetTestSupport.eventDate)
        )
        let openPR = FleetPullRequestStatus(number: 42, state: .open)

        let changed = FleetSupervisor().reduce(
            task: crashed.0,
            signal: .prChanged(taskID: running.id, pr: openPR, at: FleetTestSupport.eventDate)
        )

        #expect(crashed.0.state == .retryBackoff)
        #expect(crashed.1 == [.scheduleBackoff(taskID: running.id, attempt: 1, delayMS: 10_000)])
        #expect(changed.0.state == .awaitingReview)
        #expect(changed.0.pr == openPR)
        #expect(changed.1 == [.cancelBackoff(taskID: running.id)])

        let staleBackoff = FleetSupervisor().reduce(
            task: changed.0,
            signal: .backoffElapsed(taskID: running.id, attempt: 1, at: FleetTestSupport.eventDate)
        )
        #expect(staleBackoff.0 == changed.0)
        #expect(staleBackoff.1.isEmpty)
    }

    @Test func terminalPullRequestAfterRetryBackoffCompletesAndCleansUp() {
        let running = FleetTestSupport.task(state: .running, attempts: 1)
        let crashed = FleetSupervisor().reduce(
            task: running,
            signal: .pidExited(taskID: running.id, attempt: 1, at: FleetTestSupport.eventDate)
        )
        let terminalPR = FleetPullRequestStatus(number: 42, state: .merged)

        let changed = FleetSupervisor().reduce(
            task: crashed.0,
            signal: .prChanged(taskID: running.id, pr: terminalPR, at: FleetTestSupport.eventDate)
        )

        #expect(crashed.0.state == .retryBackoff)
        #expect(crashed.1 == [.scheduleBackoff(taskID: running.id, attempt: 1, delayMS: 10_000)])
        #expect(changed.0.state == .done)
        #expect(changed.0.pr == terminalPR)
        #expect(changed.1 == [
            .cancelBackoff(taskID: running.id),
            .cleanupWorkspace(task: changed.0),
        ])
    }

    @Test func pullRequestAfterFailedTaskExitsFailureState() {
        let failed = FleetTestSupport.task(state: .failed, attempts: 3)
        let openPR = FleetPullRequestStatus(number: 42, state: .open)
        let terminalPR = FleetPullRequestStatus(number: 43, state: .closed)

        let review = FleetSupervisor().reduce(
            task: failed,
            signal: .prChanged(taskID: failed.id, pr: openPR, at: FleetTestSupport.eventDate)
        )
        #expect(review.0.state == .awaitingReview)
        #expect(review.0.pr == openPR)
        #expect(review.1.isEmpty)

        let done = FleetSupervisor().reduce(
            task: failed,
            signal: .prChanged(taskID: failed.id, pr: terminalPR, at: FleetTestSupport.eventDate)
        )
        #expect(done.0.state == .done)
        #expect(done.0.pr == terminalPR)
        #expect(done.1 == [.cleanupWorkspace(task: done.0)])
    }
}
