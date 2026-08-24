import CmuxSimulator
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator attachment readiness")
@MainActor
struct SimulatorAttachmentReadinessTests {
    @Test("Core streaming does not wait for optional capability hydration")
    func coreStreamingPrecedesOptionalCapabilities() async {
        let recorder = AttachmentReadinessRecorder()
        let gate = AttachmentCapabilityGate()

        let hydrationTask = beginSimulatorAttachmentReadiness(
            baselineCapabilities: [.framebuffer, .touch],
            send: { recorder.events.append($0) },
            hydrate: { await gate.wait() },
            applyHydratedCapabilities: { recorder.events.append(.capabilitiesHydrated($0)) }
        )

        #expect(recorder.events == [
            .capabilities([.framebuffer, .touch]),
            .status(.streaming),
        ])

        await gate.release([.accessibility, .framebuffer, .touch])
        await hydrationTask.value

        #expect(recorder.events == [
            .capabilities([.framebuffer, .touch]),
            .status(.streaming),
            .capabilitiesHydrated([.accessibility, .framebuffer, .touch]),
        ])
    }
}
