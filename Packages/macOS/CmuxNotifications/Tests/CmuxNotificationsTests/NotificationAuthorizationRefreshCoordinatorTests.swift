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

    @Test
    func newerReadWinsWhenCallbacksFinishInReverseOrder() async {
        let reads = NotificationAuthorizationRefreshReadProbe()
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { await reads.read() }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        let older = coordinator.refresh()
        await reads.waitForRead(1)
        let newer = coordinator.refresh()
        await reads.waitForRead(2)
        reads.completeRead(1, with: .success(.authorized))
        await newer.value
        reads.completeRead(0, with: .success(.denied))
        await older.value
        #expect(published == [.authorized])
    }

    @Test
    func directGrantInvalidatesOlderRead() async {
        await expectDirectOutcomeWins(.authorized, olderResult: .denied)
    }

    @Test
    func directDenialInvalidatesOlderRead() async {
        await expectDirectOutcomeWins(.denied, olderResult: .authorized)
    }

    @Test
    func repeatedDirectOutcomeStillInvalidatesOlderRead() async {
        let reads = NotificationAuthorizationRefreshReadProbe()
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { await reads.read() }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        coordinator.accept(.authorized)
        let older = coordinator.refresh()
        await reads.waitForRead(1)
        coordinator.accept(.authorized)
        reads.completeRead(0, with: .success(.denied))
        await older.value
        #expect(published == [.authorized])
    }

    @Test
    func admissionBeforeDirectOutcomeIsInvalidEvenBeforeTaskStarts() async {
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { .success(.denied) }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        let older = coordinator.refresh()
        coordinator.accept(.authorized)
        await older.value
        #expect(published == [.authorized])
    }

    @Test
    func readAdmittedAfterDirectOutcomeRemainsEligible() async {
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { .success(.authorized) }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        coordinator.accept(.denied)
        await coordinator.refresh().value
        await coordinator.refresh().value
        #expect(published == [.denied, .authorized])
    }

    @Test
    func newReadFailureAfterDirectGrantPreservesUnknownPolicy() async {
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { .failure(.timedOut) }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        coordinator.accept(.authorized)
        await coordinator.refresh().value
        #expect(published == [.authorized, .unknown])
    }

    private func expectDirectOutcomeWins(
        _ state: NotificationAuthorizationState,
        olderResult: UserNotificationAuthorizationStatus
    ) async {
        let reads = NotificationAuthorizationRefreshReadProbe()
        var published: [NotificationAuthorizationState] = []
        let coordinator = NotificationAuthorizationRefreshCoordinator(
            statusProvider: { await reads.read() }, publish: { published.append($0) }
        )
        coordinator.markWindowSetupComplete()
        let older = coordinator.refresh()
        await reads.waitForRead(1)
        coordinator.accept(state)
        reads.completeRead(0, with: .success(olderResult))
        await older.value
        #expect(published == [state])
    }
}
