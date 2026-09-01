import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

/// Backup double whose fetches park until the test releases them, modeling
/// the per-user backup round trip on a cold launch. Uploads succeed inline.
actor GatedFetchBackup: PairedMacBackingUp {
    private var fetchStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchBlockers: [CheckedContinuation<Void, Never>] = []

    func upload(ops _: [PairedMacBackupOp]) async -> Bool { true }

    func fetchAll() async -> [PairedMacBackupRecord]? {
        await fetchSnapshot(teamID: nil, expectedUserID: nil)?.records
    }

    func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]? {
        await fetchSnapshot(teamID: teamID, expectedUserID: nil)?.records
    }

    func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: nil, expectedUserID: nil)
    }

    func fetchSnapshot(teamID: String?) async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: teamID, expectedUserID: nil)
    }

    func fetchSnapshot(teamID: String?, expectedUserID _: String?) async -> PairedMacBackupSnapshot? {
        fetchStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        if !released {
            await withCheckedContinuation { fetchBlockers.append($0) }
        }
        return PairedMacBackupSnapshot(records: [], resolvedTeamID: teamID)
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for blocker in fetchBlockers { blocker.resume() }
        fetchBlockers = []
    }

    func fetchHasBeenReleased() -> Bool { released }
}

/// Cold-launch reconnect against the PRODUCTION store stack
/// (`BackingUpPairedMacStore` over SQLite), not a test wrapper.
///
/// `ReconnectBackupConcurrencyTests` proves the composite no longer awaits
/// `refreshFromBackup` before dialing, but it does so through a wrapper whose
/// `loadAll` forwards straight to SQLite. The production store's `loadAll`
/// first runs `restoreIfNeeded`, which on a fresh process awaits the very
/// restore the concurrent refresh started. The dial then waits for the backup
/// round trip anyway; the measured device symptom is a ~1.3s claim→dial gap
/// that no preamble await explains.
@MainActor
@Suite struct ReconnectColdLaunchRestoreGateTests {
    @Test func coldLaunchDialDoesNotWaitForBackupRestoreWhenPersistedRoutesExist() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: []
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await inner.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [
                try CmxAttachRoute(
                    id: "good",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 51004),
                    priority: 0
                ),
            ],
            instanceTag: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let backup = GatedFetchBackup()
        // A fresh BackingUpPairedMacStore is a fresh process: nothing restored yet.
        let pairedStore = BackingUpPairedMacStore(inner: inner, backup: backup)
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "cold-launch-restore-gate-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        let reconnect = Task { await store.reconnectActiveMacIfAvailable(stackUserID: "user-1") }
        await backup.waitUntilFetchStarted()
        let connectedBeforeRestore = try await pollUntil(attempts: 200) {
            store.connectionState == .connected
        }
        let timeline = store.storedMacReconnectPreambleStages
            .map { "\($0.name)=+\(String(format: "%.0f", $0.offsetMilliseconds))ms" }
            .joined(separator: " ")
        #expect(
            connectedBeforeRestore,
            "the cold-launch dial must come from persisted routes while the backup restore is still in flight; preamble so far: \(timeline)"
        )
        #expect(await !backup.fetchHasBeenReleased())

        await backup.release()
        #expect(await reconnect.value)
        await store.remoteClient?.disconnect()
    }

    /// A scope with nothing on disk (fresh install, reinstall) has only the
    /// backup, so the dial must still wait for the restore instead of
    /// concluding "no Mac" from an empty local store.
    @Test func coldLaunchWithNothingPersistedWaitsForBackupRestore() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: []
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let backup = GatedFetchBackup()
        let pairedStore = BackingUpPairedMacStore(inner: inner, backup: backup)
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "cold-launch-restore-fallback-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        let reconnect = Task { await store.reconnectActiveMacIfAvailable(stackUserID: "user-1") }
        await backup.waitUntilFetchStarted()
        let finishedBeforeRestore = try await pollUntil(attempts: 30) {
            store.didFinishStoredMacReconnectAttempt
        }
        #expect(!finishedBeforeRestore, "an empty local store must not settle the attempt ahead of the restore")

        await backup.release()
        #expect(await reconnect.value == false, "the released restore carried no Mac")
        #expect(store.didFinishStoredMacReconnectAttempt)
    }
}
