import Testing
@testable import CmuxMobileShellUI

/// Startup admission contract for an explicitly injected attach URL.
///
/// The original version of this suite was written against a
/// `connectInjectedAttach(_:attachURL:_:)` coordinator API that was reworked
/// before it merged, so the file has not compiled since it landed — and a
/// compile-broken test target blocks every `cmux.xctestplan` run (the plan
/// builds all of its targets even under `-only-testing`). These tests assert
/// the same admission contract against the coordinator API that shipped; the
/// URL-connect side effects live in `CMUXMobileRootView`, which claims and
/// finishes attempts through exactly these entry points.
@Suite
struct MobileInjectedAttachStartupTests {
    @Test
    @MainActor
    func connectedInjectedAttachConsumesStartupWithoutFallback() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(attempt, outcome: .connected)

        #expect(!shouldFallBack)
        #expect(!coordinator.shouldFallBackFromInjectedAttach)
        // A consumed explicit route keeps owning startup: the saved-Mac
        // reconnect must not also dial.
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func approvalGatedInjectedAttachConsumesStartupWithoutFallback() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(
            attempt, outcome: .awaitingUserApproval
        )

        #expect(!shouldFallBack)
        #expect(!coordinator.shouldFallBackFromInjectedAttach)
        // An attach parked on the Mac-side approval prompt still owns startup:
        // the saved-Mac reconnect dialing underneath it would race the very
        // connection the user is approving.
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func failedInjectedAttachReleasesStartupToStoredReconnect() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())

        let shouldFallBack = coordinator.finishInjectedAttach(attempt, outcome: .failed)

        #expect(shouldFallBack)
        #expect(coordinator.shouldFallBackFromInjectedAttach)
        // A failed explicit route releases startup so the authenticated shell
        // is not stranded disconnected.
        #expect(coordinator.claimStoredReconnect() != nil)
    }

    @Test
    @MainActor
    func onlyOneStartupSourceCanClaimAdmission() throws {
        let coordinator = MobileStartupConnectionCoordinator()

        #expect(coordinator.claimInjectedAttach() != nil)
        #expect(coordinator.claimInjectedAttach() == nil)
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func teardownCancellationLetsLaunchRouteRetryAndIgnoresLateCompletion() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let cancelledAttempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"

        #expect(!coordinator.cancelInjectedAttach(
            cancelledAttempt,
            retryLaunchRoute: true
        ))
        #expect(coordinator.claimStoredReconnect() == nil)

        let retryAttempt = try #require(coordinator.claimInjectedAttach())

        let staleCompletion = await coordinator.connectInjectedAttach(
            cancelledAttempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }
        #expect(staleCompletion == nil)

        let completion = await coordinator.connectInjectedAttach(
            retryAttempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }

        let completedAttempt = try #require(completion)
        #expect(await recorder.values() == [attachURL])
        #expect(completedAttempt.attempt == retryAttempt)
        #expect(completedAttempt.result == .connected)
        #expect(!completedAttempt.shouldReconnectStoredMac)
    }

    @Test
    @MainActor
    func appLifetimeOwnerKeepsOneAttachAliveAcrossRootReconstruction() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"
        let connectionStarted = AsyncStream.makeStream(of: Void.self)
        let allowConnectionToFinish = AsyncStream.makeStream(of: Void.self)
        let connectionFinished = AsyncStream.makeStream(
            of: MobilePairingURLConnectionResult.self
        )

        // Hoisted out of #expect: the macro captures call arguments in
        // @Sendable closures, which rejects these non-Sendable closure
        // parameters on current toolchains.
        let startedInitialAttach = coordinator.startInjectedAttach(
            attachURL: attachURL,
            prepare: {},
            connect: { rawURL in
                await recorder.record(rawURL)
                connectionStarted.continuation.yield()
                for await _ in allowConnectionToFinish.stream.prefix(1) {}
                return .connected
            },
            onCompletion: { completion in
                connectionFinished.continuation.yield(completion.result)
            }
        )
        #expect(startedInitialAttach)

        for await _ in connectionStarted.stream.prefix(1) {}

        // A reconstructed root asks startup to run again. The app-lifetime
        // coordinator must retain the original task and consume this duplicate
        // request without starting a replacement connection.
        let startedDuplicateAttach = coordinator.startInjectedAttach(
            attachURL: attachURL,
            prepare: {},
            connect: { rawURL in
                await recorder.record(rawURL)
                return .connected
            },
            onCompletion: { completion in
                connectionFinished.continuation.yield(completion.result)
            }
        )
        #expect(startedDuplicateAttach)

        allowConnectionToFinish.continuation.yield()
        var results: [MobilePairingURLConnectionResult] = []
        for await result in connectionFinished.stream.prefix(1) {
            results.append(result)
        }

        #expect(results == [.connected])
        #expect(await recorder.values() == [attachURL])
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func duplicateAccountScopeDoesNotReplaceAnAdmittedAttach() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        var applications = 0
        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-1",
            apply: { applications += 1 }
        ) == true)

        let attempt = try #require(coordinator.claimInjectedAttach())
        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-1",
            apply: { applications += 1 }
        ) == false)

        let completion = await coordinator.connectInjectedAttach(
            attempt,
            attachURL: "cmux-ios://attach?v=2&payload=iroh-route"
        ) { _ in
            .connected
        }

        #expect(completion?.result == .connected)
        #expect(applications == 1)
    }

    @Test
    @MainActor
    func genuineAccountScopeChangeSupersedesPreviousStartupOwner() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-1",
            apply: {}
        ) == true)
        let staleAttempt = try #require(coordinator.claimInjectedAttach())

        #expect(coordinator.prepareAccountScope(
            userID: "user-1",
            teamID: "team-2",
            apply: {}
        ) == true)
        #expect(!coordinator.cancelInjectedAttach(staleAttempt))
        #expect(coordinator.claimStoredReconnect() != nil)
    }
}
