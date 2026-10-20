import Testing
@testable import CmuxWorkspaces

@Suite("RestorableAgentProcessLiveness")
struct RestorableAgentProcessLivenessTests {
    @Test("Recorded process observation preserves tri-state evidence")
    func recordedProcessObservationPreservesTriStateEvidence() {
        let missing = RestorableAgentProcessObservation(
            recordedProcessID: nil,
            processMatch: { _ in .matches }
        )
        #expect(missing.processID == nil)
        #expect(missing.liveness == .unknown)

        let invalid = RestorableAgentProcessObservation(
            recordedProcessID: -1,
            processMatch: { _ in .matches }
        )
        #expect(invalid.processID == nil)
        #expect(invalid.liveness == .exited)

        let matched = RestorableAgentProcessObservation(
            recordedProcessID: 42,
            processMatch: { _ in .matches }
        )
        #expect(matched.processID == 42)
        #expect(matched.liveness == .running)

        let mismatched = RestorableAgentProcessObservation(
            recordedProcessID: 42,
            processMatch: { _ in .mismatches }
        )
        #expect(mismatched.processID == nil)
        #expect(mismatched.liveness == .exited)

        let unknown = RestorableAgentProcessObservation(
            recordedProcessID: 42,
            processMatch: { _ in .unknown }
        )
        #expect(unknown.processID == nil)
        #expect(unknown.liveness == .unknown)
    }

    @Test("Cached running state requires matching process generation evidence")
    func cachedRunningStateRequiresMatchingProcessGenerationEvidence() {
        #expect(RestorableAgentProcessLiveness.running.revalidated(against: []) == .unknown)
        #expect(RestorableAgentProcessLiveness.running.revalidated(against: [.mismatches]) == .exited)
        #expect(RestorableAgentProcessLiveness.running.revalidated(against: [.unknown]) == .unknown)
        #expect(
            RestorableAgentProcessLiveness.running.revalidated(against: [.mismatches, .matches]) == .running
        )
        #expect(RestorableAgentProcessLiveness.exited.revalidated(against: [.matches]) == .exited)
    }

    @Test("Exact runtime evidence precedes cached and shell state")
    func exactRuntimeEvidencePrecedesCachedAndShellState() {
        #expect(
            RestorableAgentProcessLiveness.exited.resolvedWasRunning(
                fallingBackTo: .commandRunning,
                hasConfirmedRuntimeProcess: false
            ) == false
        )
        #expect(
            RestorableAgentProcessLiveness.exited.resolvedWasRunning(
                fallingBackTo: .promptIdle,
                hasConfirmedRuntimeProcess: true
            ) == true
        )
        #expect(
            RestorableAgentProcessLiveness.unknown.resolvedWasRunning(
                fallingBackTo: .commandRunning,
                hasConfirmedRuntimeProcess: false
            ) == true
        )
        #expect(
            RestorableAgentProcessLiveness.unknown.resolvedWasRunning(
                fallingBackTo: .promptIdle,
                hasConfirmedRuntimeProcess: true
            ) == true
        )
    }
}
