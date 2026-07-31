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
    func failedInjectedAttachReleasesStartupToStoredReconnect() throws {
        let coordinator = MobileStartupConnectionCoordinator()

        let attachAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)

        #expect(coordinator.finishInjectedAttach(attachAttempt, outcome: .failed))
        #expect(coordinator.claimInjectedAttach() == nil)

        let storedAttempt = try #require(coordinator.claimStoredReconnect())
        coordinator.finishStoredReconnect(storedAttempt)
        #expect(coordinator.claimStoredReconnect() != nil)
    }

    @Test
    @MainActor
    func connectedInjectedAttachKeepsExclusiveStartupOwnership() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attachAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(!coordinator.finishInjectedAttach(attachAttempt, outcome: .connected))
        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)
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
