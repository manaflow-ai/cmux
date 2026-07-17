import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite
struct IrohZeroTouchDiscoveryTests {
    private nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func cleanInstallConnectsAndPersistsOnlyAuthenticatedMac() async throws {
        let fixture = try await makeFixture(
            candidates: [try candidate(deviceID: "mac-a", endpointByte: "a")],
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(fixture.shell.connectionState == .connected)
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
        let rows = try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil)
        let saved = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(saved.macDeviceID == "mac-a")
        #expect(saved.instanceTag == "stable")
        #expect(saved.routes.map(\.kind) == [.iroh])
    }

    @Test
    func authenticatedIdentityMismatchDoesNotCreatePairing() async throws {
        let fixture = try await makeFixture(
            candidates: [try candidate(deviceID: "mac-a", endpointByte: "a")],
            reportedDeviceID: "different-mac"
        )
        defer { fixture.cleanup() }

        #expect(!(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(fixture.shell.connectionState == .disconnected)
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
        #expect(try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil).isEmpty)
    }

    @Test
    func forgottenLiveCandidateIsNeitherDialedNorRecreated() async throws {
        let fixture = try await makeFixture(
            candidates: [try candidate(deviceID: "mac-a", endpointByte: "a")],
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))
        await fixture.shell.rememberForgottenMacDeviceID(
            MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "stable"),
            scope: scope
        )

        #expect(!(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(fixture.factory.attemptedRouteIDs().isEmpty)
        #expect(try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil).isEmpty)
    }

    @Test
    func unreachableCandidateFallsThroughToNextLiveMac() async throws {
        let first = try candidate(deviceID: "mac-a", endpointByte: "a")
        let second = try candidate(deviceID: "mac-b", endpointByte: "b")
        let fixture = try await makeFixture(
            candidates: [first, second],
            reportedDeviceID: "mac-b",
            failingRouteIDs: ["iroh-mac-a"]
        )
        defer { fixture.cleanup() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a", "iroh-mac-b"])
        let rows = try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.macDeviceID == "mac-b")
    }

    @Test
    func presenceRetriesBrokerDiscoveryWhenMacStartsAfterIOS() async throws {
        let live = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = ScriptedIrohDiscovery(snapshots: [[], [live]])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }

        #expect(!(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))
        fixture.shell.applyPresenceUpdate(.online(PresenceInstance(
            deviceId: "presence-trigger-only",
            tag: "stable",
            platform: "mac",
            online: true,
            lastSeenAt: Self.fixedNow.timeIntervalSince1970 * 1_000
        )), scope: scope)

        #expect(try await pollUntil {
            fixture.shell.connectionState == .connected
                && fixture.shell.foregroundMacDeviceID == "mac-a"
        })
        #expect(discovery.callCount() == 2)
    }

    @Test
    func signOutWhileDiscoveryIsSuspendedPreventsDialAndPersistence() async throws {
        let live = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = SuspendedIrohDiscovery(candidates: [live])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }
        let reconnect = Task { @MainActor in
            await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await discovery.waitUntilRequested()

        fixture.shell.signOut()
        discovery.resume()

        #expect(!(await reconnect.value))
        #expect(fixture.factory.attemptedRouteIDs().isEmpty)
        #expect(try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil).isEmpty)
    }

    private func makeFixture(
        candidates: [MobileDiscoveredIrohMac],
        reportedDeviceID: String,
        failingRouteIDs: Set<String> = []
    ) async throws -> ZeroTouchFixture {
        try await makeFixture(
            discovery: ScriptedIrohDiscovery(snapshots: [candidates]),
            reportedDeviceID: reportedDeviceID,
            failingRouteIDs: failingRouteIDs
        )
    }

    private func makeFixture(
        discovery: any MobileIrohMacDiscovering,
        reportedDeviceID: String,
        failingRouteIDs: Set<String> = []
    ) async throws -> ZeroTouchFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: reportedDeviceID,
            instanceTag: "stable",
            displayName: "Test Mac"
        )
        let factory = ZeroTouchRouteFactory(
            router: router,
            failingRouteIDs: failingRouteIDs
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { Self.fixedNow },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: store,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "iroh-zero-touch-\(UUID().uuidString)"
            )!
        )
        return ZeroTouchFixture(
            shell: shell,
            store: store,
            factory: factory,
            directory: directory
        )
    }

    private func candidate(
        deviceID: String,
        endpointByte: Character
    ) throws -> MobileDiscoveredIrohMac {
        let endpointID = String(repeating: String(endpointByte), count: 64)
        return MobileDiscoveredIrohMac(
            deviceID: deviceID,
            displayName: "Test \(deviceID)",
            instanceTag: "stable",
            routes: [try CmxAttachRoute(
                id: "iroh-\(deviceID)",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(endpointID: endpointID),
                    pathHints: []
                ),
                priority: -10_000
            )],
            lastSeenAt: Self.fixedNow
        )
    }
}

@MainActor
private final class ScriptedIrohDiscovery: MobileIrohMacDiscovering {
    private var snapshots: [[MobileDiscoveredIrohMac]]
    private var calls = 0

    init(snapshots: [[MobileDiscoveredIrohMac]]) {
        self.snapshots = snapshots
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        let index = min(calls, max(0, snapshots.count - 1))
        calls += 1
        return snapshots.isEmpty ? [] : snapshots[index]
    }

    func callCount() -> Int { calls }
}

@MainActor
private final class SuspendedIrohDiscovery: MobileIrohMacDiscovering {
    private let candidates: [MobileDiscoveredIrohMac]
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var wasRequested = false
    private var wasResumed = false

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        wasRequested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !wasResumed {
            await withCheckedContinuation { continuation in
                resumeWaiter = continuation
            }
        }
        return candidates
    }

    func waitUntilRequested() async {
        guard !wasRequested else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume() {
        wasResumed = true
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private final class ZeroTouchRouteFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let failingRouteIDs: Set<String>
    private let lock = NSLock()
    private var attempts: [String] = []

    init(router: LivenessHostRouter, failingRouteIDs: Set<String>) {
        self.router = router
        self.failingRouteIDs = failingRouteIDs
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route.id) }
        if failingRouteIDs.contains(route.id) {
            throw ZeroTouchRouteError.unreachable
        }
        return LivenessTransport(router: router)
    }

    func attemptedRouteIDs() -> [String] {
        lock.withLock { attempts }
    }
}

private enum ZeroTouchRouteError: Error {
    case unreachable
}

@MainActor
private struct ZeroTouchFixture {
    let shell: MobileShellComposite
    let store: MobilePairedMacStore
    let factory: ZeroTouchRouteFactory
    let directory: URL

    func cleanup() {
        Task { await shell.remoteClient?.disconnect() }
        try? FileManager.default.removeItem(at: directory)
    }
}
