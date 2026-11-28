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

    /// A saved-Mac dial started while auth restores must not retry after the
    /// restore changes the account scope or signs out: the newer scope owns
    /// startup and its own dial.
    @Test
    @MainActor
    func storedReconnectSupersededByScopeChangeOrResetDoesNotOwnRetry() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-1",
            apply: {}
        ) == true)
        let restoreAttempt = try #require(coordinator.claimStoredReconnect())

        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-2",
            apply: {}
        ) == true)
        #expect(!coordinator.finishStoredReconnect(restoreAttempt))

        let signedOutAttempt = try #require(coordinator.claimStoredReconnect())
        coordinator.reset()
        #expect(!coordinator.finishStoredReconnect(signedOutAttempt))

        let currentAttempt = try #require(coordinator.claimStoredReconnect())
        #expect(coordinator.finishStoredReconnect(currentAttempt))
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

    @Test
    @MainActor
    func approvalPendingInjectedAttachKeepsExclusiveStartupOwnership() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attachAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(!coordinator.finishInjectedAttach(
            attachAttempt,
            outcome: .awaitingUserApproval
        ))
        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func cancelledInjectedAttachReleasesImmediatelyAndIgnoresLateCompletion() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let cancelledAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(coordinator.cancelInjectedAttach(cancelledAttempt))
        #expect(!coordinator.cancelInjectedAttach(cancelledAttempt))
        let fallbackAttempt = try #require(coordinator.claimStoredReconnect())
        coordinator.finishStoredReconnect(fallbackAttempt)

        coordinator.reset()
        let currentAttempt = try #require(coordinator.claimInjectedAttach())
        #expect(!coordinator.finishInjectedAttach(cancelledAttempt, outcome: .connected))
        #expect(!coordinator.finishInjectedAttach(currentAttempt, outcome: .connected))
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
