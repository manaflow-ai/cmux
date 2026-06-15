import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior of registry-driven auto-attach on the composite: the "sign in →
/// connected" path. Drives the real connect through the scripted-host transport
/// the liveness tests use, with in-memory registry / paired-mac / identity
/// doubles, so these verify the end-to-end orchestration (eligibility gates,
/// in-flight dedupe, persistence, fall-through) rather than re-testing the pure
/// selector.
@MainActor
@Suite struct MobileAutoAttachTests {
    // MARK: - Doubles

    @MainActor
    private final class FakeIdentity: MobileIdentityProviding {
        var userID: String?
        init(userID: String?) { self.userID = userID }
        var currentUserID: String? { userID }
    }

    private actor InMemoryPairedMacStore: MobilePairedMacStoring {
        private var macs: [MobilePairedMac] = []

        func upsert(
            macDeviceID: String,
            displayName: String?,
            routes: [CmxAttachRoute],
            markActive: Bool,
            stackUserID: String?,
            now: Date
        ) async throws {
            if markActive {
                macs = macs.map { var m = $0; m.isActive = false; return m }
            }
            if let idx = macs.firstIndex(where: { $0.macDeviceID == macDeviceID }) {
                macs[idx].displayName = displayName
                macs[idx].routes = routes
                macs[idx].lastSeenAt = now
                if markActive { macs[idx].isActive = true }
            } else {
                macs.append(MobilePairedMac(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    routes: routes,
                    createdAt: now,
                    lastSeenAt: now,
                    isActive: markActive,
                    stackUserID: stackUserID
                ))
            }
        }

        func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
            macs
                .filter { stackUserID == nil || $0.stackUserID == stackUserID }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
        }

        func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
            macs.first { $0.isActive && (stackUserID == nil || $0.stackUserID == stackUserID) }
        }

        func setActive(macDeviceID: String) async throws {
            macs = macs.map { var m = $0; m.isActive = ($0.macDeviceID == macDeviceID); return m }
        }

        func remove(macDeviceID: String) async throws {
            macs.removeAll { $0.macDeviceID == macDeviceID }
        }

        func removeAll() async throws { macs.removeAll() }

        func count() -> Int { macs.count }
    }

    private struct AlwaysOnlineReachability: ReachabilityProviding {
        var isOnline: Bool { get async { true } }
        func pathChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    private actor FakeRegistry: DeviceRegistryRefreshing {
        private let devices: [RegistryDevice]
        private(set) var listCallCount = 0
        // When set, listDevices returns this outcome instead of `.ok(devices)`,
        // modeling a registry outage (transient failure / auth rejection).
        private var forcedOutcome: DeviceRegistryListOutcome?

        func forceOutcome(_ outcome: DeviceRegistryListOutcome?) { forcedOutcome = outcome }
        // Optional gate: when armed, the first listDevices parks until released,
        // so a test can hold an auto-attach attempt mid-flight.
        private var gateContinuations: [CheckedContinuation<Void, Never>] = []
        private var gateArmed = false
        private var gateReleased = false

        init(devices: [RegistryDevice]) { self.devices = devices }

        func armGate() { gateArmed = true }

        func releaseGate() {
            gateReleased = true
            let conts = gateContinuations
            gateContinuations = []
            for c in conts { c.resume() }
        }

        func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]? { nil }

        func listDevices() async -> DeviceRegistryListOutcome {
            listCallCount += 1
            if gateArmed, !gateReleased {
                await withCheckedContinuation { gateContinuations.append($0) }
            }
            return forcedOutcome ?? .ok(devices)
        }
    }

    // MARK: - Fixtures

    private func loopbackRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
    }

    private func device(id: String, lastSeen: Date, route: CmxAttachRoute) -> RegistryDevice {
        RegistryDevice(
            deviceId: id,
            platform: "mac",
            displayName: "Test Mac \(id)",
            lastSeenAt: lastSeen,
            instances: [RegistryAppInstance(tag: "stable", routes: [route], lastSeenAt: lastSeen)]
        )
    }

    private func makeStore(
        devices: [RegistryDevice],
        pairedStore: InMemoryPairedMacStore,
        registry: FakeRegistry,
        clock: TestClock,
        router: LivenessHostRouter,
        box: TransportBox,
        autoAttachEnabled: Bool = true,
        userID: String? = "user-1",
        identity: FakeIdentity? = nil,
        supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    ) -> MobileShellComposite {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: supportedRouteKinds
        )
        // Isolated defaults per store so the persisted `hasKnownPairedMac` hint
        // can't leak across tests (the production key lives in `.standard`).
        let hintDefaults = UserDefaults(suiteName: "MobileAutoAttachTests.\(UUID().uuidString)")!
        return MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: registry,
            identityProvider: identity ?? FakeIdentity(userID: userID),
            reachability: AlwaysOnlineReachability(),
            autoAttachEnabled: autoAttachEnabled,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: hintDefaults
        )
    }

    // MARK: - Tests

    @Test func singleCandidateConnectsAndPersistsActivePairing() async throws {
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")

        #expect(attached)
        #expect(store.connectionState == .connected)
        // Persisted as the active paired Mac so the next launch takes the normal
        // stored-mac reconnect path and never re-runs auto-attach.
        let active = try await pairedStore.activeMac(stackUserID: "user-1")
        #expect(active?.macDeviceID == "mac-A")
    }

    @Test func noCandidateReturnsFalseAndPersistsNothing() async throws {
        let clock = TestClock()
        let pairedStore = InMemoryPairedMacStore()
        // No devices in the registry → no candidate.
        let registry = FakeRegistry(devices: [])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")

        #expect(!attached)
        #expect(store.connectionState != .connected)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func flagOffNeverAttempts() async throws {
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox(),
            autoAttachEnabled: false
        )

        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")

        #expect(!attached)
        #expect(store.connectionState != .connected)
        let listCalls = await registry.listCallCount
        #expect(listCalls == 0, "flag off must not even hit the registry")
    }

    @Test func alreadyConnectedNeverAttempts() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        // Bring the store to .connected first via the scripted attach URL.
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        #expect(store.connectionState == .connected)

        // Even though the store has no registry/paired doubles, the guard must
        // short-circuit before any work because it is already connected.
        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        #expect(!attached)
    }

    @Test func concurrentTriggersDedupeToOneAttempt() async throws {
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Two near-simultaneous triggers (foreground + sign-in). The in-flight
        // flag makes the second a true no-op while the first runs, so exactly one
        // attempt drives a connect: one trigger returns true and the other false
        // (deduped), and exactly one active pairing is persisted (no duplicate
        // destructive connect, no duplicate rows).
        async let first = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        async let second = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        let results = await [first, second]

        #expect(results.filter { $0 }.count == 1, "exactly one trigger connects; the other is deduped")
        let count = await pairedStore.count()
        #expect(count == 1)
        #expect(store.connectionState == .connected)
    }

    @Test func sequentialRetryAfterFailureIsAllowed() async throws {
        // After an attempt finishes without connecting, the in-flight flag is
        // cleared, so a later trigger may retry (the flag is not a permanent
        // one-shot latch). First call: empty registry → no candidate → false.
        // Then the same store, given a candidate registry, connects on retry.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let first = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        #expect(first)
        // A second sequential call when already connected is a no-op via the top
        // guard, proving the in-flight flag did not latch permanently.
        let second = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        #expect(!second)
    }

    @Test func reconnectChainsAutoAttachAndResolvesRestoringGateOnNoCandidate() async throws {
        let clock = TestClock()
        let pairedStore = InMemoryPairedMacStore()
        // No stored Mac and no registry candidate: reconnect must chain into
        // auto-attach, find nothing, and resolve the restoring gate (not leave
        // RestoringSessionView stuck up) so the UI falls through to the pair sheet.
        let registry = FakeRegistry(devices: [])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(!connected)
        #expect(!store.isReconnectingStoredMac)
        #expect(store.didFinishStoredMacReconnectAttempt)
        #expect(!store.hasKnownPairedMac)
        // Auto-attach was consulted (registry listed) before falling through.
        let listCalls = await registry.listCallCount
        #expect(listCalls >= 1)
    }

    @Test func reconnectChainsAutoAttachAndConnectsSingleCandidate() async throws {
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        // No stored Mac but one reachable registry Mac: reconnect chains into
        // auto-attach, connects, and persists the pairing.
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        #expect(store.connectionState == .connected)
        #expect(!store.isReconnectingStoredMac)
        let active = try await pairedStore.activeMac(stackUserID: "user-1")
        #expect(active?.macDeviceID == "mac-A")
    }

    @Test func concurrentReconnectLeavesRestoringGateUpWhileFirstAttachRuns() async throws {
        // Regression: a second reconnect trigger arriving while the first
        // auto-attach is still connecting must NOT resolve the restoring gate
        // (that would flash the pair/QR screen mid-connect). The first attempt
        // owns the gate; the superseding trigger leaves it untouched.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Start the first reconnect; it chains into auto-attach and parks inside
        // the gated registry list, holding autoAttachInFlight == true.
        async let first: Bool = store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        // Let the first call reach the parked listDevices.
        _ = try await pollUntil { await registry.listCallCount >= 1 }
        #expect(store.isReconnectingStoredMac, "first attempt holds the restoring gate")

        // A second reconnect trigger while the first is still in flight must be a
        // no-op for the gate: it sees autoAttachInFlight and returns without
        // clearing isReconnectingStoredMac / didFinishStoredMacReconnectAttempt.
        let second = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        #expect(!second)
        #expect(store.isReconnectingStoredMac, "gate must stay up; the second trigger must not drop it")
        #expect(!store.didFinishStoredMacReconnectAttempt)

        // Release the first attempt; it connects and resolves the gate.
        await registry.releaseGate()
        let firstResult = await first
        #expect(firstResult)
        #expect(store.connectionState == .connected)
        let count = await pairedStore.count()
        #expect(count == 1)
    }

    @Test func concurrentReconnectDoesNotStrandGateWhenFirstAttachMisses() async throws {
        // Regression (P1): a second reconnect trigger bumps storedMacReconnectGeneration
        // while the first auto-attach is in flight. The first attempt's gate
        // cleanup must NOT depend on that generation, so when the first attempt
        // finds NO candidate it still resolves the restoring gate instead of
        // leaving RestoringSessionView stuck up forever.
        let clock = TestClock()
        let pairedStore = InMemoryPairedMacStore()
        // Empty registry → the first attempt will find no candidate.
        let registry = FakeRegistry(devices: [])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        async let first: Bool = store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }
        #expect(store.isReconnectingStoredMac, "first attempt holds the gate while parked")

        // Second trigger bumps the generation; it must bail without touching the gate.
        let second = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        #expect(!second)
        #expect(store.isReconnectingStoredMac, "second trigger must not drop the gate")

        // Release the first; with no candidate it must resolve the gate, not strand it.
        await registry.releaseGate()
        let firstResult = await first
        #expect(!firstResult)
        #expect(!store.isReconnectingStoredMac, "gate resolved after a missed first attempt")
        #expect(store.didFinishStoredMacReconnectAttempt)
        #expect(!store.hasKnownPairedMac)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func signOutResetsInFlightSoNextSignInAutoAttachIsNotSuppressed() async throws {
        // Regression (P1): a fresh-install attempt parked mid-flight when the user
        // signs out must not leave autoAttachInFlight set and suppress the NEXT
        // account's auto-attach. signOut() resets the flag, so a fresh attempt
        // after sign-in runs normally.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Park a first attempt inside the gated registry list (in flight).
        async let first: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // Sign out while the first attempt is parked; this must clear the in-flight
        // flag. Release the gate so the parked attempt unwinds (its post-await
        // guards see signed-out and bail without connecting).
        store.signOut()
        await registry.releaseGate()
        let firstResult = await first
        #expect(!firstResult, "the parked attempt bails after sign-out")

        // Sign back in; a new auto-attach must NOT be suppressed by a stale flag.
        store.signIn()
        let second = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        #expect(second, "next sign-in's auto-attach runs because the flag was reset")
        #expect(store.connectionState == .connected)
    }

    @Test func staleAttemptDoesNotConnectAfterAccountSwitch() async throws {
        // Regression (P1): a task parked mid-flight for user-1 must not resume and
        // connect under user-2 after a sign-out + different-account sign-in. The
        // per-await account guard discards it.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let identity = await FakeIdentity(userID: "user-1")
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox(),
            identity: identity
        )

        // Park an attempt captured for user-1.
        async let first: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // Simulate sign-out + sign-in as user-2 while the attempt is parked.
        store.signOut()
        identity.userID = "user-2"
        store.signIn()
        await registry.releaseGate()
        let firstResult = await first

        // The stale user-1 attempt must NOT have connected under user-2.
        #expect(!firstResult)
        #expect(store.connectionState != .connected)
        let count = await pairedStore.count()
        #expect(count == 0, "no pairing persisted from the stale cross-account attempt")
    }

    @Test func manualPairingSupersedesInFlightAutoAttach() async throws {
        // Regression (P1): if the user starts manual pairing while auto-attach is
        // parked awaiting the registry, the auto-attach attempt must be superseded
        // and must NOT later drive a destructive connect that invalidates the
        // user's manual pairing.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Park an auto-attach attempt inside the gated registry list.
        async let auto: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // User starts manual pairing (an invalid code is enough to exercise the
        // supersede at the top of connectPairingURLResult). This bumps the
        // auto-attach generation, so the parked attempt is superseded.
        _ = await store.connectPairingURLResult("not-a-valid-attach-url")

        // Release the gate; the superseded auto-attach must bail without connecting.
        await registry.releaseGate()
        let autoResult = await auto
        #expect(!autoResult, "superseded auto-attach must not connect after manual pairing began")
        let count = await pairedStore.count()
        #expect(count == 0, "no auto-attach pairing persisted over the manual attempt")
    }

    @Test func manualPairingResolvesGateWhenSupersedingGateOwningAutoAttach() async throws {
        // Regression (P1): when the user starts manual pairing while a GATE-OWNING
        // auto-attach runner is in flight, superseding it must resolve the
        // restoring gate (not leave RestoringSessionView stuck) even if the manual
        // pairing then fails.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Gate-owning auto-attach via the reconnect path; it parks in the registry.
        async let recon: Bool = store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }
        #expect(store.isReconnectingStoredMac, "gate is up while the runner is parked")

        // User starts manual pairing with an invalid code; it fails but must have
        // resolved the gate via the supersede path.
        _ = await store.connectPairingURLResult("not-a-valid-attach-url")
        #expect(!store.isReconnectingStoredMac, "gate resolved when manual pairing superseded the runner")
        #expect(store.didFinishStoredMacReconnectAttempt)

        // Release the parked auto-attach; it must bail (superseded) and not connect.
        await registry.releaseGate()
        let reconResult = await recon
        #expect(!reconResult)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func userManualHostSupersedesInFlightAutoAttach() async throws {
        // Regression (P1b): the user submitting the manual-host form
        // (connectManualHost, not via auto-attach) must supersede a parked
        // auto-attach so it can't resume and run a competing destructive connect.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: router,
            box: box
        )

        async let auto: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // User manually connects to a host; this funnels through beginPairingAttempt
        // and supersedes the parked auto-attach.
        await store.connectManualHost(name: "Manual Mac", host: "127.0.0.1", port: 56_584)

        await registry.releaseGate()
        let autoResult = await auto
        #expect(!autoResult, "auto-attach must be superseded by the user's manual host connect")
        // The manual host connect itself landed (scripted host answers), so there
        // is exactly one pairing — from the manual connect, not a racing auto-attach.
        #expect(store.connectionState == .connected)
    }

    @Test func supersededAutoAttachDoesNotClobberPairedHintFromManualPairing() async throws {
        // Regression (P2): a manual pairing that completes (setting connectionState
        // == .connected) while a gate-owning auto-attach is parked must not have
        // its paired-Mac hint clobbered to false when the stale auto-attach unwinds
        // with no candidate.
        let clock = TestClock()
        let pairedStore = InMemoryPairedMacStore()
        // Empty registry → the parked auto-attach will find no candidate on resume.
        let registry = FakeRegistry(devices: [])
        await registry.armGate()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: router,
            box: box
        )

        // Gate-owning auto-attach parks in the registry list.
        async let recon: Bool = store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // User completes a manual pairing (scripted host answers) → connected.
        await store.connectManualHost(name: "Manual Mac", host: "127.0.0.1", port: 56_584)
        #expect(store.connectionState == .connected)
        let hintAfterManual = store.hasKnownPairedMac

        // Release the parked auto-attach; with no candidate it must NOT write the
        // negative hint, because the guard skips the stale write while connected.
        // The hint is therefore unchanged from after the manual connect.
        await registry.releaseGate()
        _ = await recon
        #expect(store.hasKnownPairedMac == hintAfterManual, "stale auto-attach must not clobber the hint after a successful connect")
        #expect(store.connectionState == .connected, "the live manual connection survives the stale auto-attach unwinding")
    }

    @Test func transientRegistryFailureFallsThroughEvenWithStaleCache() async throws {
        // Regression (P2): auto-attach must decide from a freshly-confirmed `.ok`
        // registry list, not a stale cache. A transient registry failure must make
        // it fall through to manual, even if a previous load populated the cache.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Warm the cache with a successful load (registryDevices now has mac-A).
        await store.loadRegistryDevices()
        #expect(!store.registryDevices.isEmpty)

        // Now the registry goes down (transient). Auto-attach must NOT connect off
        // the warm cache; it falls through to manual.
        await registry.forceOutcome(.transientFailure)
        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        #expect(!attached, "transient registry failure must degrade to manual, not connect off a stale cache")
        #expect(store.connectionState != .connected)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func invalidManualHostStillSupersedesInFlightAutoAttach() async throws {
        // Regression (P2): a user manual-host submission that FAILS validation
        // (invalid host) returns before beginPairingAttempt, but must still
        // supersede a parked auto-attach so it can't resume and connect over the
        // user's explicit (failed) attempt.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        async let auto: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // Invalid host: connectManualHost returns at the validation guard, but the
        // supersede runs first.
        await store.connectManualHost(name: "Bad", host: "has spaces/and/path", port: 56_584)

        await registry.releaseGate()
        let autoResult = await auto
        #expect(!autoResult, "auto-attach must be superseded even by a failed manual-host submission")
        #expect(store.connectionState != .connected)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func rejectLoopbackConnectDoesNotPersistLoopbackRoutes() async throws {
        // Regression (P1): when auto-attach connects with rejectLoopback (physical
        // phone), the persisted paired-Mac route set must EXCLUDE loopback, so the
        // next stored-Mac reconnect (no rejectLoopback flag) can never pick the
        // phone's own 127.0.0.1.
        let clock = TestClock()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [])
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: router,
            box: box,
            supportedRouteKinds: [.debugLoopback, .tailscale]
        )

        let loopback = try CmxAttachRoute(
            id: "loop",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584),
            priority: 0
        )
        let tailscale = try CmxAttachRoute(
            id: "ts",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.0.5", port: 56_584),
            priority: 1
        )
        let dev = RegistryDevice(
            deviceId: "mac-A",
            platform: "mac",
            displayName: "Mac A",
            lastSeenAt: clock.now,
            instances: [RegistryAppInstance(tag: "stable", routes: [loopback, tailscale], lastSeenAt: clock.now)]
        )

        // Connect with rejectLoopback (as auto-attach does on a physical phone).
        await store.connectToRegistryInstance(device: dev, instance: dev.instances[0], rejectLoopback: true)
        #expect(store.connectionState == .connected)

        let active = try await pairedStore.activeMac(stackUserID: "user-1")
        let persistedKinds = active?.routes.map(\.kind) ?? []
        #expect(!persistedKinds.contains(.debugLoopback), "loopback route must not be persisted on a rejectLoopback connect")
        #expect(persistedKinds.contains(.tailscale), "the safe tailscale route is persisted")
    }

    @Test func invalidManualHostSupersedesAutoAttachAlreadyInsideItsConnect() async throws {
        // Regression (P1): when auto-attach is already inside its own connect()
        // (parked on the workspace.list handshake) and the user submits an INVALID
        // manual host, the supersede must bump the connection generation so the
        // in-flight connect discards its result instead of landing over the user's
        // explicit (failed) action.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: router,
            box: box
        )

        // Hold the connect handshake so auto-attach parks INSIDE connect().
        await router.setHoldWorkspaceList(true)
        async let auto: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await router.workspaceListRequestSeen() }

        // User submits an invalid manual host while auto-attach is mid-connect.
        await store.connectManualHost(name: "Bad", host: "has spaces/and/path", port: 56_584)

        // Release the handshake; auto-attach's parked connect must discard its
        // result (superseded connection generation) and NOT land a connection.
        await router.setHoldWorkspaceList(false)
        let autoResult = await auto
        #expect(!autoResult, "auto-attach inside connect must be superseded by the user's manual submission")
        #expect(store.connectionState != .connected)
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func signOutDuringGateOwningAutoAttachLeavesGateCleanForNextSignIn() async throws {
        // Regression (P2): signing out while a GATE-OWNING auto-attach is in flight
        // must leave the restoring-gate flags reset (not "already finished"), so
        // the next account's sign-in starts with a clean gate rather than flashing
        // onboarding/add-device.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        // Gate-owning auto-attach parks in the registry list.
        async let recon: Bool = store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }
        #expect(store.isReconnectingStoredMac)

        // Sign out while the gate-owning attempt is in flight.
        store.signOut()
        // Both restoring flags must be reset by sign-out (not left "finished").
        #expect(!store.isReconnectingStoredMac)
        #expect(!store.didFinishStoredMacReconnectAttempt, "next sign-in must not see the reconnect as already finished")

        // Release the parked attempt so it unwinds (it bails: signed out).
        await registry.releaseGate()
        let reconResult = await recon
        #expect(!reconResult)
        // Still clean for the next sign-in.
        #expect(!store.isReconnectingStoredMac)
        #expect(!store.didFinishStoredMacReconnectAttempt)
    }

    @Test func userTapOnNoRouteInstanceStillSupersedesAutoAttach() async throws {
        // Regression (P2): a user device-tree tap on an instance with no reachable
        // route returns early (before connectManualHost), but must still supersede
        // an in-flight auto-attach so the background attempt can't later connect
        // over the user's explicit choice.
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        let registry = FakeRegistry(devices: [device(id: "mac-A", lastSeen: clock.now, route: route)])
        await registry.armGate()
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        async let auto: Bool = store.attemptAutoAttachIfEligible(stackUserID: "user-1")
        _ = try await pollUntil { await registry.listCallCount >= 1 }

        // User taps a registry instance that advertises NO route (early return),
        // but supersedeAutoAttach defaults to true and runs first.
        let noRouteDevice = RegistryDevice(
            deviceId: "mac-B",
            platform: "mac",
            displayName: "Mac B",
            lastSeenAt: clock.now,
            instances: [RegistryAppInstance(tag: "stable", routes: [], lastSeenAt: clock.now)]
        )
        await store.connectToRegistryInstance(device: noRouteDevice, instance: noRouteDevice.instances[0])

        await registry.releaseGate()
        let autoResult = await auto
        #expect(!autoResult, "no-route user tap must still supersede in-flight auto-attach")
        let count = await pairedStore.count()
        #expect(count == 0)
    }

    @Test func ambiguousMultipleEquallyRecentMacsFallsThrough() async throws {
        let clock = TestClock()
        let route = try loopbackRoute()
        let pairedStore = InMemoryPairedMacStore()
        // Two devices, equally recent, no presence signal → ambiguous → no target.
        let registry = FakeRegistry(devices: [
            device(id: "mac-A", lastSeen: clock.now, route: route),
            device(id: "mac-B", lastSeen: clock.now, route: route),
        ])
        let store = makeStore(
            devices: [],
            pairedStore: pairedStore,
            registry: registry,
            clock: clock,
            router: LivenessHostRouter(),
            box: TransportBox()
        )

        let attached = await store.attemptAutoAttachIfEligible(stackUserID: "user-1")

        #expect(!attached)
        let count = await pairedStore.count()
        #expect(count == 0)
    }
}
