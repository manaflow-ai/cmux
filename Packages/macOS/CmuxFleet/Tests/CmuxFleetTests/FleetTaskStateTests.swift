import CmuxFleet
import Testing

@Suite("FleetTaskState")
struct FleetTaskStateTests {
    @Test func terminalAndActiveHelpersClassifyStates() {
        #expect(FleetTaskState.done.isTerminal)
        #expect(FleetTaskState.failed.isTerminal)
        #expect(FleetTaskState.cancelled.isTerminal)
        #expect(!FleetTaskState.running.isTerminal)

        #expect(FleetTaskState.provisioning.isActive)
        #expect(FleetTaskState.launching.isActive)
        #expect(FleetTaskState.running.isActive)
        #expect(FleetTaskState.needsInput.isActive)
        #expect(FleetTaskState.stalled.isActive)
        #expect(FleetTaskState.retryBackoff.isActive)
        #expect(!FleetTaskState.queued.isActive)
        #expect(!FleetTaskState.awaitingReview.isActive)
        #expect(!FleetTaskState.done.isActive)
    }

    @Test func transitionTableMatchesExpectedEdges() {
        let expected: [FleetTaskState: Set<FleetTaskState>] = [
            .queued: [.queued, .provisioning, .cancelled],
            .provisioning: [.provisioning, .launching, .failed, .cancelled],
            .launching: [.launching, .running, .retryBackoff, .awaitingReview, .done, .failed, .cancelled],
            .running: [.running, .needsInput, .retryBackoff, .awaitingReview, .done, .failed, .cancelled],
            .needsInput: [.needsInput, .running, .retryBackoff, .awaitingReview, .done, .failed, .cancelled],
            .stalled: [.stalled, .retryBackoff, .done, .failed, .cancelled],
            .retryBackoff: [.retryBackoff, .launching, .cancelled],
            .awaitingReview: [.awaitingReview, .done, .queued, .cancelled],
            .done: [.done],
            .failed: [.failed, .queued],
            .cancelled: [.cancelled, .queued],
        ]

        for from in FleetTaskState.allCases {
            for to in FleetTaskState.allCases {
                #expect(FleetTaskState.canTransition(from: from, to: to) == (expected[from]?.contains(to) ?? false))
            }
        }
    }

    @Test func supervisorStateChangesAreLegalTransitions() {
        for scenario in SupervisorSignalKind.allCases {
            for state in FleetTaskState.allCases {
                let task = FleetTestSupport.task(state: state)
                let reduced = FleetSupervisor().reduce(
                    task: task,
                    signal: scenario.signal(at: FleetTestSupport.eventDate)
                )
                if reduced.0.state != state {
                    #expect(FleetTaskState.canTransition(from: state, to: reduced.0.state))
                }
            }
        }
    }
}
