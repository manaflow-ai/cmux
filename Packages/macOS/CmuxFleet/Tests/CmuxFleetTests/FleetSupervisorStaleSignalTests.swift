import CmuxFleet
import Testing

@Suite("FleetSupervisor stale signals")
struct FleetSupervisorStaleSignalTests {
    @Test func staleAgentSessionStartedIsIgnored() {
        let task = FleetTestSupport.task(state: .launching, attempts: 2)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .agentSessionStarted(
                taskID: task.id,
                attempt: 1,
                sessionID: "session",
                pid: 42,
                at: FleetTestSupport.eventDate
            )
        )

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }

    @Test func staleAgentStoppedIsIgnored() {
        let task = FleetTestSupport.task(
            state: .running,
            attempts: 2,
            pr: FleetPullRequestStatus(number: 12, state: .merged)
        )

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .agentStopped(taskID: task.id, attempt: 1, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }

    @Test func stalePidExitIsIgnored() {
        let task = FleetTestSupport.task(state: .running, attempts: 2)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .pidExited(taskID: task.id, attempt: 1, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }

    @Test func staleStallTimeoutIsIgnored() {
        let task = FleetTestSupport.task(state: .needsInput, attempts: 2, isBlocked: true)

        let reduced = FleetSupervisor().reduce(
            task: task,
            signal: .stallTimeout(taskID: task.id, attempt: 1, at: FleetTestSupport.eventDate)
        )

        #expect(reduced.0 == task)
        #expect(reduced.1.isEmpty)
    }
}
