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

        let hydrationTask = SimulatorAttachmentReadiness.begin(
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

@MainActor
private final class AttachmentReadinessRecorder {
    var events: [SimulatorWorkerOutbound] = []
}

private actor AttachmentCapabilityGate {
    private var continuation: CheckedContinuation<Set<SimulatorCapability>, Never>?
    private var releasedCapabilities: Set<SimulatorCapability>?

    func wait() async -> Set<SimulatorCapability> {
        if let releasedCapabilities {
            return releasedCapabilities
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ capabilities: Set<SimulatorCapability>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: capabilities)
        } else {
            releasedCapabilities = capabilities
        }
    }
}
