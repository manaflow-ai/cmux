import Testing
@testable import CmuxNotifications

@MainActor
@Suite(.serialized)
struct NotificationAuthorizationRefreshCoordinatorTests {
    @Test
    func startupAndActivationCoalesceUntilSetup() async {
        var reads = 0
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { reads += 1; return .success(.denied) },
            publish: { published.append($0) }
        )
        await coordinator.refresh().value
        await coordinator.refresh().value
        await coordinator.refresh().value
        #expect(reads == 0)
        #expect(published.isEmpty)
        await coordinator.markWindowSetupComplete()?.value
        #expect(reads == 1)
        #expect(published == [.denied])
        #expect(coordinator.markWindowSetupComplete() == nil)
        #expect(reads == 1)
    }

    @Test
    func earlyStatusAndGrantPublishOnlyTheLatestOutcome() async {
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { .success(.authorized) },
            publish: { published.append($0) }
        )
        coordinator.accept(.notDetermined)
        coordinator.accept(.authorized)
        #expect(published.isEmpty)
        await coordinator.markWindowSetupComplete()?.value
        #expect(published == [.authorized])
        coordinator.accept(.authorized)
        #expect(published == [.authorized])
    }

    @Test
    func failuresAndUnchangedOutcomesDoNotRepublish() async {
        var result: Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure> = .success(.unknown(-1))
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { result }, publish: { published.append($0) }
        )
        await coordinator.refresh().value
        await coordinator.markWindowSetupComplete()?.value
        #expect(published.isEmpty)
        result = .success(.provisional)
        await coordinator.refresh().value
        await coordinator.refresh().value
        #expect(published == [.provisional])
        result = .failure(.timedOut)
        await coordinator.refresh().value
        await coordinator.refresh().value
        #expect(published == [.provisional, .unknown])
    }
}
