import CmuxMobileShellModel
import Testing

@Suite
struct MobileStartupConnectionCoordinatorTests {
    @Test
    @MainActor
    func beginsRouteAdmissionWithoutAnExternalTransportReadinessBarrier() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let attempt = try #require(coordinator.claimInjectedAttach())
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"

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
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"

        #expect(!coordinator.cancelInjectedAttach(
            cancelledAttempt,
            retryLaunchRoute: true
        ))
        // A retryable release returns ownership to unclaimed so the SAME
        // launch route can claim again on the next startup pass. (The original
        // ShellUI copy of this test asserted `claimStoredReconnect() == nil`
        // here, which never matched the shipped behavior — the iOS-only
        // ShellUI test target had no CI lane, so the failure was latent.)
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

    /// The pre-bootstrap early dial applies the RESTORED keychain scope, then
    /// claims the stored reconnect. When the auth bootstrap later resolves the
    /// SAME account and team, its duplicate scope application must coalesce
    /// (the early connection survives) and its own reconnect request must be
    /// refused while the early attempt still owns startup, so exactly one
    /// startup dial runs.
    @Test
    @MainActor
    func bootstrapConfirmingTheRestoredScopeCoalescesAroundTheEarlyDial() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        var applications = 0
        #expect(coordinator.prepareAccountScope(
            userID: "restored-user",
            teamID: "restored-team",
            apply: { applications += 1 }
        ) == true)
        let earlyAttempt = try #require(coordinator.claimStoredReconnect())

        // Bootstrap resolves the same scope: coalesced, owner untouched.
        #expect(coordinator.prepareAccountScope(
            userID: "restored-user",
            teamID: "restored-team",
            apply: { applications += 1 }
        ) == false)
        #expect(applications == 1)
        #expect(coordinator.claimStoredReconnect() == nil)

        // The early dial finishing releases startup ownership normally.
        coordinator.finishStoredReconnect(earlyAttempt)
        #expect(coordinator.claimStoredReconnect() != nil)
    }

    /// When the auth bootstrap reveals a DIFFERENT account (or team) than the
    /// restored session the early dial ran under, the scope application must
    /// supersede the early stored-reconnect owner: the stale attempt's finish
    /// is ignored and the new scope claims a fresh startup dial.
    @Test
    @MainActor
    func bootstrapRevealingADifferentAccountSupersedesTheEarlyDial() throws {
        let coordinator = MobileStartupConnectionCoordinator()
        var applications = 0
        #expect(coordinator.prepareAccountScope(
            userID: "restored-user",
            teamID: "restored-team",
            apply: { applications += 1 }
        ) == true)
        let earlyAttempt = try #require(coordinator.claimStoredReconnect())

        #expect(coordinator.prepareAccountScope(
            userID: "bootstrapped-user",
            teamID: "restored-team",
            apply: { applications += 1 }
        ) == true)
        #expect(applications == 2)

        // The superseding scope owns startup: the new dial claims first, and
        // the orphaned early attempt's completion must not release it.
        let replacementAttempt = try #require(coordinator.claimStoredReconnect())
        coordinator.finishStoredReconnect(earlyAttempt)
        #expect(coordinator.claimStoredReconnect() == nil)
        coordinator.finishStoredReconnect(replacementAttempt)
        #expect(coordinator.claimStoredReconnect() != nil)
    }

    /// An injected launch attach keeps startup priority over the early dial:
    /// within one startup pass the attach claims first, and while it is in
    /// flight the stored reconnect may not start. If the early dial DID claim
    /// first (no launch route existed yet), a late launch attach does not
    /// steal the coordinator mid-dial; it runs once the stored attempt
    /// releases ownership (the transport-level supersede handles a live
    /// pairing URL replacing an in-flight dial).
    @Test
    @MainActor
    func lateInjectedAttachRunsAfterTheEarlyDialReleasesOwnership() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        #expect(coordinator.prepareAccountScope(
            userID: "restored-user",
            teamID: nil,
            apply: {}
        ) == true)
        let earlyAttempt = try #require(coordinator.claimStoredReconnect())

        // While the early dial owns startup, an arriving launch attach is
        // consumed without starting a competing connection.
        #expect(coordinator.claimInjectedAttach() == nil)
        let recorder = MobileInjectedAttachURLRecorder()
        let attachURL = "cmux-ios://attach?v=2&payload=iroh-route"
        // Hoisted out of #expect: the macro captures call arguments in
        // @Sendable closures, which rejects these non-Sendable closure
        // parameters on current toolchains.
        let consumedLateAttach = coordinator.startInjectedAttach(
            attachURL: attachURL,
            prepare: {},
            connect: { rawURL in
                await recorder.record(rawURL)
                return .connected
            },
            onCompletion: { _ in }
        )
        #expect(consumedLateAttach)
        #expect(await recorder.values().isEmpty)

        // Once the early dial releases startup, the launch attach claims and
        // connects.
        coordinator.finishStoredReconnect(earlyAttempt)
        let attempt = try #require(coordinator.claimInjectedAttach())
        let completion = await coordinator.connectInjectedAttach(
            attempt,
            attachURL: attachURL
        ) { rawURL in
            await recorder.record(rawURL)
            return .connected
        }
        #expect(completion?.result == .connected)
        #expect(await recorder.values() == [attachURL])
        #expect(coordinator.claimStoredReconnect() == nil)
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
