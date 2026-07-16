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
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func livenessAndForegroundRecoveryCoalesceOnOneIrohReplacement() async throws {
        let fixture = try await makeRecoveryOwnerFixture()
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let firstClient = try #require(fixture.store.remoteClient)
        let first = try #require(fixture.box.get())
        await first.close()
        fixture.store.suspendForegroundRefresh()
        fixture.clock.advance(by: 61)
        fixture.store.resumeForegroundRefresh()
        fixture.store.recoverMobileConnection(trigger: .networkChange)

        let recovered = try await pollUntil {
            guard let replacement = fixture.store.remoteClient else { return false }
            return replacement !== firstClient && fixture.store.connectionState == .connected
        }
        #expect(recovered)
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func staleRecoveryCleanupCannotClearNewerAttempt() async throws {
        let fixture = try await makeRecoveryOwnerFixture(heldConnectAttempts: [2])
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let firstClient = try #require(fixture.store.remoteClient)
        let first = try #require(fixture.box.get())
        await first.close()
        #expect(await fixture.factory.waitForAttemptCount(2))

        fixture.store.recoverMobileConnection(trigger: .presencePush)
        fixture.factory.releaseHeldConnects()

        let recovered = try await pollUntil {
            fixture.store.connectionState == .connected
                && fixture.store.remoteClient !== firstClient
                && fixture.store.macConnectionStatus == .connected
                && fixture.store.isRecoveringConnection == false
        }
        #expect(recovered)
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
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
        await backup.blockFutureFetches()
        await fixture.router.holdWorkspaceListRequest(number: 2)
        fixture.store.resumeForegroundRefresh()
        #expect(await backup.waitForBlockedFetch())

        let recoveredWithoutServer = try await pollUntil(attempts: 100) {
            guard let replacement = fixture.store.remoteClient else { return false }
            return replacement !== firstClient && fixture.store.connectionState == .connected
        }
        #expect(recoveredWithoutServer)
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh])
    }

    @Test func authenticatedPresenceRetriesFailedEarlyIrohRedial() async throws {
        let fixture = try await makeRecoveryOwnerFixture(failingConnectAttempts: [2])
        defer { fixture.release() }

        #expect(await fixture.store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        let first = try #require(fixture.box.get())
        await first.close()

        #expect(try await pollUntil {
            fixture.store.connectionState == .disconnected
                && fixture.store.connectionRecoveryFailed
        })
        fixture.store.recoverMobileConnection(trigger: .presencePush)

        #expect(try await pollUntil {
            fixture.store.connectionState == .connected
                && fixture.store.activeRoute?.kind == .iroh
        })
        #expect(fixture.factory.attemptedKinds() == [.iroh, .iroh, .iroh])
    }

    private func makeRecoveryOwnerFixture(
        backup: (any PairedMacBackingUp)? = nil,
        failingConnectAttempts: Set<Int> = [],
        heldConnectAttempts: Set<Int> = []
    ) async throws -> RecoveryOwnerFixture {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = SequencedKindTransportFactory(
            router: router,
            box: box,
            failingConnectAttempts: failingConnectAttempts,
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
    private let failingConnectAttempts: Set<Int>
    private let heldConnectAttempts: Set<Int>
    private let lock = NSLock()
    private var kinds: [CmxAttachTransportKind] = []
    private var heldReleased = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var attemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        router: LivenessHostRouter,
        box: TransportBox,
        failingConnectAttempts: Set<Int>,
        heldConnectAttempts: Set<Int>
    ) {
        self.router = router
        self.box = box
        self.failingConnectAttempts = failingConnectAttempts
        self.heldConnectAttempts = heldConnectAttempts
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let attempt = lock.withLock { () -> Int in
            kinds.append(route.kind)
            let count = kinds.count
            let ready = attemptWaiters.filter { $0.0 <= count }
            attemptWaiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
            return count
        }
        let transport = SequencedLivenessTransport(
            base: LivenessTransport(router: router),
            factory: self,
            attempt: attempt,
            shouldFail: failingConnectAttempts.contains(attempt),
            shouldHold: heldConnectAttempts.contains(attempt)
        )
        box.set(transport.base)
        return transport
    }

    func attemptedKinds() -> [CmxAttachTransportKind] { lock.withLock { kinds } }

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
