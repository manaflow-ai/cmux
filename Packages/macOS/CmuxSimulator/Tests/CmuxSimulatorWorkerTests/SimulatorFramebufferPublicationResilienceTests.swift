import Testing

@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer publication resilience")
struct SimulatorFramebufferPublicationResilienceTests {
    @Test("Persistent publication failures stop after bounded backoff")
    func persistentFailuresStopAfterBoundedBackoff() {
        var policy = SimulatorFramebufferPublicationFailurePolicy(
            maximumConsecutiveFailureCount: 3,
            initialRetryDelay: .milliseconds(20)
        )

        #expect(policy.retryDelayAfterFailure() == .milliseconds(20))
        #expect(policy.retryDelayAfterFailure() == .milliseconds(40))
        #expect(policy.retryDelayAfterFailure() == nil)

        policy.recordSuccess()
        #expect(policy.retryDelayAfterFailure() == .milliseconds(20))
    }

    @Test("Host adoption drains retired transport bookkeeping")
    func hostAdoptionDrainsRetiredTransportBookkeeping() async {
        let ledger = SimulatorFramebufferRetirementLedger(maximumRetiredNameCount: 2)
        #expect(await ledger.recordRetired("/cmux-sim-frame-first"))
        #expect(await ledger.recordRetired("/cmux-sim-frame-second"))
        let acceptedOverflow = await ledger.recordRetired("/cmux-sim-frame-overflow")
        #expect(!acceptedOverflow)

        #expect(await ledger.count == 2)
        #expect(await ledger.takeRetiredNames() == [
            "/cmux-sim-frame-first",
            "/cmux-sim-frame-second",
        ])
        #expect(await ledger.count == 0)
    }
}
