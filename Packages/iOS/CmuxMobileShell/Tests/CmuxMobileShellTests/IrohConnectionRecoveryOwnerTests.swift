import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func establishedIrohSessionRedialsOnceAfterTransportDies() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let initialReconnectGeneration = fixture.store.storedMacReconnectGenerationForTesting()
        let firstClient = try #require(fixture.store.remoteClient)
        let first = try #require(fixture.box.get())
        await first.close()

        let recovered = try await pollUntil {
            guard let replacement = fixture.store.remoteClient else { return false }
            return replacement !== firstClient
                && fixture.store.connectionState == .connected
                && fixture.store.activeRoute?.kind == .iroh
        }
        #expect(recovered)
        #expect(
            fixture.store.storedMacReconnectGenerationForTesting()
                == initialReconnectGeneration + 1
        )
        let attemptedKinds = fixture.factory.attemptedKinds()
        #expect(attemptedKinds.count >= 2)
        #expect(attemptedKinds.allSatisfy { $0 == .iroh })
    }

    @Test func livenessAndForegroundRecoveryCoalesceOnOneIrohReplacement() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let firstClient = try #require(fixture.store.remoteClient)
        fixture.store.suspendForegroundRefresh()
        fixture.clock.advance(by: 61)
        fixture.store.resumeForegroundRefresh()
        // Deliver the watchdog's definitive verdict in the same main-actor turn
        // as foreground claimed its probe. The liveness signal must supersede
        // that probe before either trigger can install a second replacement.
        fixture.store.recoverDeadConnection(trigger: .liveness, expectedClient: firstClient)
        fixture.store.recoverMobileConnection(trigger: .networkChange)

        let recovered = try await pollUntil {
            guard let replacement = fixture.store.remoteClient else { return false }
            return replacement !== firstClient && fixture.store.connectionState == .connected
        }
        #expect(recovered)
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func staleRecoveryCleanupCannotClearNewerAttempt() async throws {
        let owner = MobileConnectionRecoveryOwner()
        defer { owner.cancel() }
        let generation = UUID()
        let staleAttempt = try #require(owner.begin(
            trigger: "foreground",
            sourceConnectionGeneration: generation,
            probing: true
        ))
        owner.install(Task {}, for: staleAttempt)
        let replacementAttempt = try #require(owner.supersedeProbeWithRedial(
            trigger: "liveness",
            sourceConnectionGeneration: generation
        ))
        owner.install(Task {}, for: replacementAttempt)

        owner.clearTask(for: staleAttempt)

        #expect(owner.phase == .redialing(replacementAttempt))
        #expect(owner.task != nil)
        #expect(owner.isCurrent(replacementAttempt))
    }

    @Test func localPinnedIrohRecoveryDoesNotWaitForBackupRefresh() async throws {
        let backup = BlockingSecondFetchBackup()
        let fixture = try await makeRecoveryOwnerFixture(backup: backup)
        defer {
            fixture.release()
            Task { await backup.release() }
        }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let firstClient = try #require(fixture.store.remoteClient)
        let backing = try #require(fixture.store.pairedMacStore as? BackingUpPairedMacStore)
        await backup.blockFutureFetches()
        let blockedRefresh = Task {
            await backing.refreshFromBackup(stackUserID: "user-1")
        }
        #expect(await backup.waitForBlockedFetch())
        let first = try #require(fixture.box.get())
        await first.close()

        let recoveredWithoutServer = try await pollUntil(attempts: 100) {
            guard let replacement = fixture.store.remoteClient else { return false }
            return replacement !== firstClient && fixture.store.connectionState == .connected
        }
        #expect(recoveredWithoutServer)
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
        await backup.release()
        await blockedRefresh.value
    }

    @Test func signOutCancelsInFlightIrohRecoveryOwner() async throws {
        let fixture = try await makeRecoveryOwnerFixture(heldConnectAttempts: [2])
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let first = try #require(fixture.box.get())
        await first.close()

        #expect(await fixture.factory.waitForAttemptCount(2))
        #expect(fixture.store.connectionRecoveryOwner.isActive)

        fixture.store.signOut()

        #expect(fixture.store.connectionRecoveryOwner.phase == .idle)
        #expect(fixture.store.connectionRecoveryOwner.task == nil)
        #expect(!fixture.store.isRecoveringConnection)
    }

    @Test func authenticatedPresenceRetriesFailedEarlyIrohRedial() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let firstClient = try #require(fixture.store.remoteClient)
        // Keep every post-drop dial failing until the first owner reaches its
        // terminal failed phase. This avoids coupling the assertion to a
        // transport ordinal that unrelated requests on the dying client can
        // legitimately consume before synchronous retirement reaches it.
        fixture.factory.setConnectsFailing(true)
        let first = try #require(fixture.box.get())
        await first.close()

        #expect(try await pollUntil {
            fixture.store.connectionState == .disconnected
                && fixture.store.connectionRecoveryFailed
        })
        fixture.factory.setConnectsFailing(false)
        let scope = try #require(
            await fixture.store.currentScopeSnapshot(userID: "user-1")
        )
        fixture.store.applyPresenceUpdate(.online(PresenceInstance(
            deviceId: "test-mac",
            tag: "default",
            platform: "mac",
            online: true,
            lastSeenAt: fixture.clock.now.timeIntervalSince1970 * 1_000,
            routes: [try iroh()]
        )), scope: scope)

        #expect(try await pollUntil {
            let subscribeCount = await fixture.router.count(of: "mobile.events.subscribe")
            return fixture.store.connectionState == .connected
                && fixture.store.remoteClient !== firstClient
                && fixture.store.activeRoute?.kind == .iroh
                && fixture.store.macConnectionStatus == .connected
                && fixture.store.isRecoveringConnection == false
                && fixture.store.connectionRecoveryFailed == false
                && subscribeCount >= 2
        })
        let attemptedKinds = fixture.factory.attemptedKinds()
        #expect(attemptedKinds.count >= 3)
        #expect(attemptedKinds.allSatisfy { $0 == .iroh })
    }

    @Test func responseTimeoutLeavesTheLiveIrohClientAlone() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let client = try #require(fixture.store.remoteClient)
        let generation = fixture.store.connectionGeneration

        fixture.store.handleMacAvailabilityFailureIfCurrent(
            after: MobileShellConnectionError.requestTimedOut,
            expectedClient: client,
            expectedGeneration: generation
        )

        #expect(fixture.store.remoteClient === client)
        #expect(fixture.store.connectionState == .connected)
        #expect(fixture.store.macConnectionStatus == .connected)
        #expect(fixture.factory.attemptedKinds() == [.iroh])
    }

    @Test func storedReconnectDoesNotReplaceAnAlreadyLiveIrohClient() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let liveClient = try #require(fixture.store.remoteClient)
        let liveGeneration = fixture.store.connectionGeneration

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))

        #expect(fixture.store.remoteClient === liveClient)
        #expect(fixture.store.connectionGeneration == liveGeneration)
        #expect(fixture.store.connectionState == .connected)
        #expect(fixture.factory.attemptedKinds() == [.iroh])
        #expect(await fixture.router.count(of: "mobile.events.subscribe") == 1)
    }

    @Test func stalledWriteRedialsExactCurrentIrohClientOnce() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let client = try #require(fixture.store.remoteClient)
        let generation = fixture.store.connectionGeneration

        fixture.store.handleMacAvailabilityFailureIfCurrent(
            after: MobileShellConnectionError.transportWriteTimedOut,
            expectedClient: client,
            expectedGeneration: generation
        )

        #expect(try await pollUntil {
            guard let replacement = fixture.store.remoteClient else { return false }
            let subscribeCount = await fixture.router.count(of: "mobile.events.subscribe")
            return replacement !== client
                && fixture.store.connectionState == .connected
                && fixture.store.activeRoute?.kind == .iroh
                && fixture.store.macConnectionStatus == .connected
                && fixture.store.isRecoveringConnection == false
                && subscribeCount >= 2
        })
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
    }

    private func makeRecoveryOwnerFixture(
        backup: (any PairedMacBackingUp)? = nil,
        heldConnectAttempts: Set<Int> = []
    ) async throws -> RecoveryOwnerFixture {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = SequencedKindTransportFactory(
            router: router,
            box: box,
            heldConnectAttempts: heldConnectAttempts
        )
        let (inner, directory) = try makePairedMacStore()
        try await inner.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try iroh()],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let pairedStore: any MobilePairedMacStoring
        if let backup {
            pairedStore = BackingUpPairedMacStore(inner: inner, backup: backup)
        } else {
            pairedStore = inner
        }
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "iroh-recovery-owner-\(UUID().uuidString)")!
        )
        return RecoveryOwnerFixture(
            store: store,
            clock: clock,
            router: router,
            box: box,
            factory: factory,
            directory: directory
        )
    }
}

@MainActor
private struct RecoveryOwnerFixture {
    let store: MobileShellComposite
    let clock: TestClock
    let router: LivenessHostRouter
    let box: TransportBox
    let factory: SequencedKindTransportFactory
    let directory: URL

    func release() {
        factory.releaseHeldConnects()
        Task { await router.releaseAllHeld() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SequencedKindTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let heldConnectAttempts: Set<Int>
    private let lock = NSLock()
    private var kinds: [CmxAttachTransportKind] = []
    private var connectsFailing = false
    private var heldReleased = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var attemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        router: LivenessHostRouter,
        box: TransportBox,
        heldConnectAttempts: Set<Int>
    ) {
        self.router = router
        self.box = box
        self.heldConnectAttempts = heldConnectAttempts
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let (attempt, shouldFail) = lock.withLock { () -> (Int, Bool) in
            kinds.append(route.kind)
            let count = kinds.count
            let ready = attemptWaiters.filter { $0.0 <= count }
            attemptWaiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
            return (count, connectsFailing)
        }
        let transport = SequencedLivenessTransport(
            base: LivenessTransport(router: router),
            factory: self,
            attempt: attempt,
            shouldFail: shouldFail,
            shouldHold: heldConnectAttempts.contains(attempt)
        )
        box.set(transport.base)
        return transport
    }

    func attemptedKinds() -> [CmxAttachTransportKind] { lock.withLock { kinds } }

    func setConnectsFailing(_ failing: Bool) {
        lock.withLock { connectsFailing = failing }
    }

    func waitForAttemptCount(_ count: Int) async -> Bool {
        if lock.withLock({ kinds.count >= count }) { return true }
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if kinds.count >= count { return true }
                attemptWaiters.append((count, continuation))
                return false
            }
            if immediate { continuation.resume() }
        }
        return true
    }

    func waitForHeldRelease() async {
        if lock.withLock({ heldReleased }) { return }
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if heldReleased { return true }
                heldWaiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    func releaseHeldConnects() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            heldReleased = true
            defer { heldWaiters = [] }
            return heldWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private actor SequencedLivenessTransport: CmxByteTransport {
    let base: LivenessTransport
    private let factory: SequencedKindTransportFactory
    private let attempt: Int
    private let shouldFail: Bool
    private let shouldHold: Bool

    init(
        base: LivenessTransport,
        factory: SequencedKindTransportFactory,
        attempt: Int,
        shouldFail: Bool,
        shouldHold: Bool
    ) {
        self.base = base
        self.factory = factory
        self.attempt = attempt
        self.shouldFail = shouldFail
        self.shouldHold = shouldHold
    }

    func connect() async throws {
        if shouldHold { await factory.waitForHeldRelease() }
        if shouldFail { throw RouteRecordingTransportError.routeFailed }
        try await base.connect()
    }

    func receive() async throws -> Data? { try await base.receive() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func close() async { await base.close() }
}

private actor BlockingSecondFetchBackup: PairedMacBackingUp {
    private var fetchCount = 0
    private var shouldBlockFetches = false
    private var released = false
    private var blocked = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func upload(ops _: [PairedMacBackupOp]) async -> Bool { true }
    func fetchAll() async -> [PairedMacBackupRecord]? { await fetchSnapshot()?.records }

    func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: nil, expectedUserID: nil)
    }

    func fetchSnapshot(
        teamID _: String?,
        expectedUserID _: String?
    ) async -> PairedMacBackupSnapshot? {
        fetchCount += 1
        if shouldBlockFetches, !released {
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return PairedMacBackupSnapshot(records: [], deletedMacDeviceIDs: [])
    }

    func waitForBlockedFetch() async -> Bool {
        if blocked { return true }
        await withCheckedContinuation { blockedWaiters.append($0) }
        return true
    }

    func blockFutureFetches() { shouldBlockFetches = true }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
