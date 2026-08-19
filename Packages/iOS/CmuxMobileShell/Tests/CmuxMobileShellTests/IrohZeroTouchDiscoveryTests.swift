import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
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
        #expect(await fixture.router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
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
    func canonicalUUIDDeviceIDComparisonIgnoresLetterCase() async throws {
        let canonicalID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let fixture = try await makeFixture(
            candidates: [try candidate(deviceID: canonicalID, endpointByte: "a")],
            reportedDeviceID: canonicalID.uppercased()
        )
        defer { fixture.cleanup() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(await fixture.router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: 1
        ))
        #expect(fixture.shell.connectionState == .connected)
        let rows = try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.map(\.macDeviceID) == [canonicalID])
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
    func hiddenLiveCandidateIsNeitherDialedNorRecreated() async throws {
        let fixture = try await makeFixture(
            candidates: [try candidate(deviceID: "mac-a", endpointByte: "a")],
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))
        await fixture.shell.rememberHiddenMacDeviceID(
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
    func malformedDuplicateCannotHideLaterAuthenticatedCandidate() async throws {
        let valid = try candidate(deviceID: "mac-a", endpointByte: "a")
        let malformed = MobileDiscoveredIrohMac(
            deviceID: valid.deviceID,
            displayName: valid.displayName,
            instanceTag: valid.instanceTag,
            routes: [],
            lastSeenAt: valid.lastSeenAt.addingTimeInterval(-1)
        )
        let fixture = try await makeFixture(
            candidates: [malformed, valid],
            reportedDeviceID: "mac-a"
        )
        defer { fixture.cleanup() }

        #expect(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
        let rows = try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.map(\.macDeviceID) == ["mac-a"])
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
        #expect(try await pollUntil { discovery.callCount() == 3 })
    }

    @Test
    func unrelatedPresenceStillWakesBrokerDiscoveryWhenStoredActiveMacIsStale() async throws {
        let live = try candidate(deviceID: "mac-live", endpointByte: "b")
        let stale = try candidate(deviceID: "mac-stale", endpointByte: "c")
        let fixture = try await makeFixture(
            candidates: [live],
            reportedDeviceID: "mac-live"
        )
        defer { fixture.cleanup() }
        try await fixture.store.upsert(
            macDeviceID: stale.deviceID,
            displayName: stale.displayName,
            routes: stale.routes,
            instanceTag: stale.instanceTag,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: stale.lastSeenAt
        )
        await fixture.shell.loadPairedMacs()
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))

        fixture.shell.applyPresenceUpdate(.online(PresenceInstance(
            deviceId: "unrelated-presence-host",
            tag: "stable",
            platform: "mac",
            online: true,
            lastSeenAt: Date().timeIntervalSince1970 * 1_000
        )), scope: scope)

        #expect(try await pollUntil {
            fixture.shell.connectionState == .connected
                && fixture.shell.foregroundMacDeviceID == "mac-live"
        })
        #expect(Array(fixture.factory.attemptedRouteIDs().prefix(2)) == ["iroh-mac-stale", "iroh-mac-live"])
    }

    @Test
    func storedRouteDialsBeforeSlowZeroTouchDiscoveryCompletes() async throws {
        let saved = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = SuspendedIrohDiscovery(candidates: [])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a"
        )
        defer {
            discovery.resume()
            fixture.cleanup()
        }
        try await fixture.store.upsert(
            macDeviceID: saved.deviceID,
            displayName: saved.displayName,
            routes: saved.routes,
            instanceTag: saved.instanceTag,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: saved.lastSeenAt
        )
        await fixture.shell.loadPairedMacs()

        let reconnect = Task { @MainActor in
            await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let dialed = try await pollUntil {
            fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"]
        }

        #expect(
            dialed,
            "a saved authenticated route must not wait behind broker discovery"
        )
        #expect(await reconnect.value)
        await discovery.waitUntilRequested()
        #expect(discovery.requestCount() == 1)
        discovery.resume()
    }

    @Test
    func storedReconnectDiscoversAndPersistsCompatibleSiblingInstances() async throws {
        let candidates = [
            try candidate(
                deviceID: "shared-mac",
                endpointByte: "a",
                instanceTag: "phand1",
                routeID: "iroh-phand1"
            ),
            try candidate(
                deviceID: "shared-mac",
                endpointByte: "b",
                instanceTag: "phand2",
                routeID: "iroh-phand2"
            ),
            try candidate(
                deviceID: "shared-mac",
                endpointByte: "c",
                instanceTag: "phand3",
                routeID: "iroh-phand3"
            ),
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        var routers: [String: LivenessHostRouter] = [:]
        for candidate in candidates {
            let router = LivenessHostRouter()
            await router.setHostIdentity(
                deviceID: candidate.deviceID,
                instanceTag: candidate.instanceTag,
                displayName: candidate.displayName
            )
            routers[candidate.routes[0].id] = router
        }
        let factory = RoutedZeroTouchFactory(routers: routers)
        let defaults = UserDefaults(
            suiteName: "iroh-sibling-discovery-\(UUID().uuidString)"
        )!
        defaults.set(true, forKey: "multiMacAggregation")
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { Self.fixedNow },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: store,
            buildCompatibilityPolicy: .development(
                expectedInstanceTag: "phand1",
                additionalInstanceTags: ["phand2", "phand3"]
            ),
            personalIrohDiscovery: ScriptedIrohDiscovery(
                snapshots: [candidates]
            ),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        defer {
            for (_, subscription) in shell.secondaryMacSubscriptions {
                subscription.cancel()
            }
            Task { await shell.remoteClient?.disconnect() }
            try? FileManager.default.removeItem(at: directory)
        }
        let foreground = candidates[0]
        try await store.upsert(
            macDeviceID: foreground.deviceID,
            displayName: foreground.displayName,
            routes: foreground.routes,
            instanceTag: foreground.instanceTag,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: foreground.lastSeenAt
        )
        await shell.loadPairedMacs()

        #expect(await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(try await pollUntil {
            shell.liveMacConnections.count == 3
                && shell.pairedMacs.count == 3
        })
        let rows = try await store.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(rows.compactMap(\.instanceTag).sorted() == [
            "phand1", "phand2", "phand3",
        ])
        #expect(rows.first(where: \.isActive)?.instanceTag == "phand1")
        #expect(Set(factory.attemptedRouteIDs()) == [
            "iroh-phand1", "iroh-phand2", "iroh-phand3",
        ])
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

    @Test
    func pairGrantRetryAfterCoalescesPresenceRecoveryStorm() async throws {
        let live = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = ScriptedIrohDiscovery(snapshots: [[live]])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a",
            rateLimitedRouteIDs: ["iroh-mac-a"]
        )
        defer { fixture.cleanup() }

        #expect(!(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(discovery.callCount() == 1)
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))

        for index in 0 ..< 5 {
            fixture.shell.applyPresenceUpdate(.online(PresenceInstance(
                deviceId: "presence-\(index)",
                tag: "stable",
                platform: "mac",
                online: true,
                lastSeenAt: Self.fixedNow.timeIntervalSince1970 * 1_000
            )), scope: scope)
            await fixture.shell.pushedRouteSyncTask?.value
        }

        #expect(discovery.callCount() == 1)
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
    }

    @Test
    func transientDialFailureCoalescesIdenticalPresenceRecoveryStorm() async throws {
        let live = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = ScriptedIrohDiscovery(snapshots: [[live]])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a",
            failingRouteIDs: ["iroh-mac-a"]
        )
        defer { fixture.cleanup() }

        #expect(!(await fixture.shell.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a"])
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))
        let unchanged = PresenceInstance(
            deviceId: "presence-trigger-only",
            tag: "stable",
            platform: "mac",
            online: true,
            lastSeenAt: Self.fixedNow.timeIntervalSince1970 * 1_000
        )

        for _ in 0 ..< 5 {
            fixture.shell.applyPresenceUpdate(.online(unchanged), scope: scope)
            await fixture.shell.pushedRouteSyncTask?.value
            #expect(try await pollUntil { !fixture.shell.isRecoveringConnection })
        }

        #expect(fixture.factory.attemptedRouteIDs() == ["iroh-mac-a", "iroh-mac-a"])
    }

    /// Discovery hands back exclusively Iroh-route candidates, so the strict
    /// Tailscale connection method must skip the broker lookup entirely: no
    /// discovery request, no candidates, and therefore no Iroh dial downstream.
    @Test func tailscaleOnlyMethodSkipsZeroTouchIrohDiscovery() async throws {
        let live = try candidate(deviceID: "mac-a", endpointByte: "a")
        let discovery = ScriptedIrohDiscovery(snapshots: [[live]])
        let fixture = try await makeFixture(
            discovery: discovery,
            reportedDeviceID: "mac-a",
            connectionMethod: .tailscale
        )
        defer { fixture.cleanup() }
        let scope = try #require(
            await fixture.shell.currentScopeSnapshot(userID: "user-1")
        )

        let secondary = await fixture.shell.discoverSecondaryZeroTouchIrohCandidates(
            scope: scope,
            excluding: []
        )
        let launch = await fixture.shell.discoverZeroTouchIrohCandidates(
            scope: scope,
            generation: fixture.shell.storedMacReconnectGeneration,
            excluding: []
        )

        #expect(secondary.isEmpty)
        #expect(launch.isEmpty)
        #expect(discovery.callCount() == 0)
        #expect(fixture.factory.attemptedRouteIDs().isEmpty)
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
        failingRouteIDs: Set<String> = [],
        rateLimitedRouteIDs: Set<String> = [],
        connectionMethod: MobileConnectionMethod? = nil
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
            failingRouteIDs: failingRouteIDs,
            rateLimitedRouteIDs: rateLimitedRouteIDs
        )
        let methodStore = connectionMethod.map { method in
            let defaults = UserDefaults(
                suiteName: "iroh-zero-touch-method-\(UUID().uuidString)"
            )!
            defaults.set(
                method.rawValue,
                forKey: MobileConnectionMethodStore.methodKey
            )
            return MobileConnectionMethodStore(defaults: defaults)
        }
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { Self.fixedNow },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: store,
            connectionMethodStore: methodStore,
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
            router: router,
            directory: directory
        )
    }

    private func candidate(
        deviceID: String,
        endpointByte: Character,
        instanceTag: String = "stable",
        routeID: String? = nil,
        extraRoutes: [CmxAttachRoute] = []
    ) throws -> MobileDiscoveredIrohMac {
        let endpointID = String(repeating: String(endpointByte), count: 64)
        return MobileDiscoveredIrohMac(
            deviceID: deviceID,
            displayName: "Test \(deviceID)",
            instanceTag: instanceTag,
            routes: [try CmxAttachRoute(
                id: routeID ?? "iroh-\(deviceID)",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(endpointID: endpointID),
                    pathHints: []
                ),
                priority: -10_000
            )] + extraRoutes,
            lastSeenAt: Self.fixedNow
        )
    }
}

private final class RoutedZeroTouchFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let routers: [String: LivenessHostRouter]
    private let lock = NSLock()
    private var attempts: [String] = []

    init(routers: [String: LivenessHostRouter]) {
        self.routers = routers
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route.id) }
        guard let router = routers[route.id] else {
            throw ZeroTouchRouteError.unreachable
        }
        return LivenessTransport(router: router)
    }

    func attemptedRouteIDs() -> [String] {
        lock.withLock { attempts }
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

    func invalidateDiscovery(forMacDeviceID _: String) async {}

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

    func invalidateDiscovery(forMacDeviceID _: String) async {}

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

    func requestCount() -> Int { wasRequested ? 1 : 0 }
}

private final class ZeroTouchRouteFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let failingRouteIDs: Set<String>
    private let rateLimitedRouteIDs: Set<String>
    private let lock = NSLock()
    private var attempts: [String] = []

    init(
        router: LivenessHostRouter,
        failingRouteIDs: Set<String>,
        rateLimitedRouteIDs: Set<String>
    ) {
        self.router = router
        self.failingRouteIDs = failingRouteIDs
        self.rateLimitedRouteIDs = rateLimitedRouteIDs
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route.id) }
        if failingRouteIDs.contains(route.id) {
            throw ZeroTouchRouteError.unreachable
        }
        if rateLimitedRouteIDs.contains(route.id) {
            throw ZeroTouchRouteError.rateLimited
        }
        return LivenessTransport(router: router)
    }

    func attemptedRouteIDs() -> [String] {
        lock.withLock { attempts }
    }
}

private enum ZeroTouchRouteError: CmxRetryAfterProviding {
    case unreachable
    case rateLimited

    var retryAfterSeconds: Int? {
        self == .rateLimited ? 120 : nil
    }
}

@MainActor
private struct ZeroTouchFixture {
    let shell: MobileShellComposite
    let store: MobilePairedMacStore
    let factory: ZeroTouchRouteFactory
    let router: LivenessHostRouter
    let directory: URL

    func cleanup() {
        Task { await shell.remoteClient?.disconnect() }
        try? FileManager.default.removeItem(at: directory)
    }
}
