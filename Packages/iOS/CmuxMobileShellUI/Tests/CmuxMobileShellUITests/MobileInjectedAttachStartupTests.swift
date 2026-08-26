import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileInjectedAttachStartupTests {
    @Test
    @MainActor
    func beginsRouteAdmissionWithoutAnExternalTransportReadinessBarrier() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=injected-route"

        let completion = await coordinator.connectInjectedAttach(
            attempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return MobilePairingURLConnectionResult.connected
        }

        let completedAttempt = try #require(completion)
        #expect(await recorder.values() == [attachURL])
        #expect(completedAttempt.result == .connected)
        #expect(!completedAttempt.shouldReconnectStoredMac)
        #expect(coordinator.claimStoredReconnect() == nil)
    }

    @Test
    @MainActor
    func teardownCancellationLetsLaunchRouteRetryAndIgnoresLateCompletion() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let cancelledAttempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=injected-route"

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
        let attachURL = "cmux-ios://attach?v=2&payload=injected-route"
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
            attachURL: "cmux-ios://attach?v=2&payload=injected-route"
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

private actor MobileInjectedAttachURLRecorder {
    private var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }

    func values() -> [String] {
        urls
    }
}
