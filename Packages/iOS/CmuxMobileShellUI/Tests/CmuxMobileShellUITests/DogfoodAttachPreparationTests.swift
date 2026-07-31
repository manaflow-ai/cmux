import Testing
@testable import CmuxMobileShellUI

@Suite
struct DogfoodAttachPreparationTests {
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
