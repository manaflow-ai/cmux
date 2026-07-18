import Testing
@testable import CmuxMobileShellUI

@Suite
struct DogfoodAttachPreparationTests {
    @Test
    @MainActor
    func waitsForTransportReadinessBeforeConsumingAttachURL() async {
        let recorder = DogfoodAttachPreparationRecorder()
        let preparation = DogfoodAttachPreparation {
            await recorder.record("ready")
        }

        await preparation.run {
            await recorder.record("attach")
        }

        #expect(await recorder.values() == ["ready", "attach"])
    }

    @Test
    @MainActor
    func injectedAttachExclusivelyOwnsStartupAcrossRepeatedLifecycleCallbacks() throws {
        let coordinator = MobileStartupConnectionCoordinator()

        let attachAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)

        coordinator.finishInjectedAttach(attachAttempt)

        // Consuming the explicit launch route is terminal for this signed-in
        // startup. A later onAppear/auth callback must not silently restore a
        // different saved Mac after the requested attach finishes.
        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)

        coordinator.reset()

        let storedAttempt = try #require(coordinator.claimStoredReconnect())
        #expect(coordinator.claimStoredReconnect() == nil)
        #expect(coordinator.claimInjectedAttach() == nil)
        coordinator.finishStoredReconnect(storedAttempt)
        #expect(coordinator.claimStoredReconnect() != nil)
    }
}

private actor DogfoodAttachPreparationRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}
