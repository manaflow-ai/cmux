import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// The launch reconnect used to AWAIT the per-user backup refresh before
// dialing, which was the dominant slice of a measured ~0.9s pre-dial hole on
// cold launch. It now dials immediately from persisted state while the
// refresh runs concurrently; only the refreshed-route retry after a local
// dial failure waits for the refresh outcome (feeding the existing
// `freshReconnectRoutesAfterLocalFailure` path). These tests pin both halves
// with a refresh that blocks until the test releases it.

/// Forwards persistence to a real SQLite store while making
/// `refreshFromBackup` block until the test releases it. `onRefresh` runs
/// inside the released refresh, modeling the backup merge writing fresher
/// routes into the local store before the refresh completes.
actor BlockedBackupRefreshPairedMacStore: MobilePairedMacStoring, PairedMacBackupRefreshing {
    private let inner: MobilePairedMacStore
    private var refreshStartedFlag = false
    private var refreshCompletedFlag = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockers: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var onRefresh: (@Sendable (MobilePairedMacStore) async -> Void)?

    init(inner: MobilePairedMacStore) {
        self.inner = inner
    }

    func setOnRefresh(_ body: @escaping @Sendable (MobilePairedMacStore) async -> Void) {
        onRefresh = body
    }

    // MARK: - PairedMacBackupRefreshing

    func refreshFromBackup(stackUserID _: String?) async {
        refreshStartedFlag = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        if !released {
            await withCheckedContinuation { blockers.append($0) }
        }
        if let onRefresh { await onRefresh(inner) }
        refreshCompletedFlag = true
    }

    func cancelInFlightRestores() async {}

    func waitUntilRefreshStarted() async {
        if refreshStartedFlag { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for blocker in blockers { blocker.resume() }
        blockers = []
    }

    func refreshStarted() -> Bool { refreshStartedFlag }
    func refreshCompleted() -> Bool { refreshCompletedFlag }

    // MARK: - MobilePairedMacStoring forwarding

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }

    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            routes: routes
        )
    }
}

@MainActor
@Suite struct ReconnectBackupConcurrencyTests {
    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func makeStore(
        pairedMacStore: BlockedBackupRefreshPairedMacStore,
        factory: RouteRecordingTransportFactory,
        clock: TestClock
    ) -> MobileShellComposite {
        MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "backup-concurrency-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
    }

    /// A pairing whose persisted routes are dialable (the relay-method default
    /// synthesizes its dial target) must connect while the backup refresh is
    /// still in flight: the refresh runs concurrently and never gates the dial.
    @Test func reconnectDialsWhileBackupRefreshIsStillInFlight() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: []
        )
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await inner.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try loopbackRoute(id: "good", port: 51001)],
            instanceTag: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let blocked = BlockedBackupRefreshPairedMacStore(inner: inner)
        let store = makeStore(pairedMacStore: blocked, factory: factory, clock: clock)

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected, "the dial must complete from persisted state alone")
        #expect(store.connectionState == .connected)
        await blocked.waitUntilRefreshStarted()
        #expect(
            await !blocked.refreshCompleted(),
            "the reconnect must not have waited for the blocked backup refresh"
        )
        await blocked.release()
        await store.remoteClient?.disconnect()
    }

    /// When every persisted route fails locally, the refreshed-route retry
    /// must WAIT for the concurrent backup refresh and then dial the route the
    /// merge produced, preserving the pre-restructure retry semantics.
    @Test func refreshedRouteRetryAwaitsBackupRefreshOutcome() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000]
        )
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await inner.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try loopbackRoute(id: "stale", port: 51000)],
            instanceTag: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let blocked = BlockedBackupRefreshPairedMacStore(inner: inner)
        let refreshedRoute = try loopbackRoute(id: "fresh", port: 51001)
        let mergeTime = clock.now.addingTimeInterval(1)
        await blocked.setOnRefresh { inner in
            try? await inner.upsert(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                routes: [refreshedRoute],
                instanceTag: nil,
                markActive: true,
                stackUserID: "user-1",
                teamID: nil,
                now: mergeTime
            )
        }
        let store = makeStore(pairedMacStore: blocked, factory: factory, clock: clock)

        let reconnect = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await blocked.waitUntilRefreshStarted()
        let staleDialed = try await pollUntil {
            factory.attemptedPorts().contains(51000)
        }
        #expect(staleDialed, "the persisted stale route dials first, without the refresh")
        #expect(
            !factory.attemptedPorts().contains(51001),
            "the refreshed route cannot dial before the refresh outcome lands"
        )
        #expect(store.connectionState != .connected)

        await blocked.release()
        let connected = await reconnect.value

        #expect(connected, "the retry must use the route the backup merge produced")
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedPorts().contains(51001))
        #expect(await blocked.refreshCompleted())
        await store.remoteClient?.disconnect()
    }
}
