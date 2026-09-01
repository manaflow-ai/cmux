import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Make-before-break roaming for the relay (.websocket) foreground route:
// a network path change dials a parallel replacement session while the old
// one keeps serving, and swaps only when the replacement is admitted.
// Scripted transports model the relay; the LivenessHostRouter answers the
// Mac side of both sessions.

/// Models the NETWORK PATH the roaming candidate dials over, not the fate of
/// one transport object. A production candidate client may dial more than
/// once (the pipelined connect-time subscribe's `ensureConnected` and the
/// workspace-list exchange's fresh dial after a failure), and every dial on
/// the same path behaves the same way: a dead path refuses each attempt, a
/// settling path parks each attempt. Scripting a fate per transport instance
/// silently diverges from that wire the moment a feature adds or removes one
/// dial, which is exactly how the pipelined-subscribe feature made a
/// "failing" replacement succeed on its second, unscripted dial.
final class RoamingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    enum PathState: Sendable {
        /// Dials complete against the scripted host.
        case up
        /// Dials refuse immediately (the new path cannot carry the relay).
        case down
        /// Dials park mid-connect until `resolvePath(up:)` (path settling).
        case parked
    }

    private let router: LivenessHostRouter
    private let lock = NSLock()
    private var pathState: PathState = .up
    private var transports: [RoamingScriptedTransport] = []

    init(router: LivenessHostRouter) {
        self.router = router
    }

    /// New dials refuse immediately until the path changes.
    func setPathDown() {
        lock.withLock { pathState = .down }
    }

    /// New dials park mid-connect until `resolvePath(up:)`.
    func parkPath() {
        lock.withLock { pathState = .parked }
    }

    /// Settle the path: parked dials resume (completing when `up`, refusing
    /// when not) and every later dial follows the new state.
    func resolvePath(up: Bool) async {
        let parked = lock.withLock {
            pathState = up ? .up : .down
            return transports
        }
        for transport in parked {
            await transport.resolveParkedConnects(up: up)
        }
    }

    func currentPathState() -> PathState {
        lock.withLock { pathState }
    }

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = RoamingScriptedTransport(router: router, factory: self)
        lock.withLock { transports.append(transport) }
        return transport
    }

    func transportCount() -> Int {
        lock.withLock { transports.count }
    }

    func transport(at index: Int) -> RoamingScriptedTransport? {
        lock.withLock {
            transports.indices.contains(index) ? transports[index] : nil
        }
    }
}

/// One dialed transport over the factory's path. Connect behavior is read
/// from the factory's CURRENT path state at dial time, so a candidate's
/// second dial on a dead path fails exactly like its first.
actor RoamingScriptedTransport: CmxByteTransport {
    private let base: LivenessTransport
    private let factory: RoamingTransportFactory
    private var parkedConnects: [CheckedContinuation<Bool, Never>] = []

    init(router: LivenessHostRouter, factory: RoamingTransportFactory) {
        base = LivenessTransport(router: router)
        self.factory = factory
    }

    func connect() async throws {
        switch factory.currentPathState() {
        case .up:
            try await base.connect()
        case .down:
            throw MobileShellConnectionError.connectionClosed
        case .parked:
            let pathCameUp = await withCheckedContinuation { continuation in
                parkedConnects.append(continuation)
            }
            guard pathCameUp else {
                throw MobileShellConnectionError.connectionClosed
            }
            try await base.connect()
        }
    }

    func resolveParkedConnects(up: Bool) {
        let parked = parkedConnects
        parkedConnects = []
        for continuation in parked {
            continuation.resume(returning: up)
        }
    }

    func receive() async throws -> Data? {
        try await base.receive()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func close() async {
        await base.close()
    }

    func isClosedForTesting() async -> Bool {
        await base.isClosedForTesting()
    }

    func deliver(_ frame: Data) async {
        await base.deliver(frame)
    }
}

@MainActor
@Suite struct MobileShellRoamingSwapTests {
    private func makePairedMacStore() throws -> MobilePairedMacStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
    }

    /// A store connected to its stored Mac over the relay method's one
    /// synthesized WebSocket route (no persisted routes at all, like a real
    /// relay pairing), which makes `.networkChange` recovery take the
    /// make-before-break roaming path.
    private func makeRelayConnectedStore(
        router: LivenessHostRouter,
        factory: RoamingTransportFactory,
        clock: TestClock
    ) async throws -> MobileShellComposite {
        let pairedStore = try makePairedMacStore()
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.websocket]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "roaming-swap-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        let connected = await store.reconnectActiveMacIfAvailable(
            stackUserID: "user-1"
        )
        #expect(connected, "scripted relay connect must succeed")
        #expect(store.activeRoute?.kind == .websocket)
        let ownerSettled = try await pollUntil {
            !store.connectionRecoveryOwner.isActive
        }
        #expect(ownerSettled, "initial connect must not leave a recovery attempt active")
        return store
    }

    @Test func networkChangeSwapsWithoutTearingDownServingRelaySession() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let factory = RoamingTransportFactory(router: router)
        let store = try await makeRelayConnectedStore(
            router: router,
            factory: factory,
            clock: clock
        )
        let servingClient = try #require(store.remoteClient)
        let servingTransport = try #require(factory.transport(at: 0))
        let subscribesBeforeSwap = await router.count(of: "mobile.events.subscribe")

        // Park the new path so the mid-dial invariants are visible.
        factory.parkPath()
        store.recoverMobileConnection(trigger: .networkChange)

        let dialStarted = try await pollUntil { factory.transportCount() >= 2 }
        #expect(dialStarted, "a parallel replacement dial must start")
        // Make: the old session is untouched while the replacement connects.
        #expect(store.remoteClient === servingClient)
        #expect(store.connectionState == .connected)
        #expect(!store.isRecoveringConnection,
                "a roaming dial must not surface reconnecting UI while the old session serves")
        #expect(await !servingTransport.isClosedForTesting())
        #expect(store.connectionRecoveryOwner.isRedialingOrValidating,
                "the recovery owner must arbitrate the roaming attempt")

        // Break: only after the replacement is admitted.
        await factory.resolvePath(up: true)
        let swapped = try await pollUntil {
            store.remoteClient != nil && store.remoteClient !== servingClient
        }
        #expect(swapped, "the admitted replacement must be adopted as foreground")
        #expect(store.connectionState == .connected)
        let oldClosed = try await pollUntil {
            await servingTransport.isClosedForTesting()
        }
        #expect(oldClosed, "the displaced session must be disconnected, not leaked")
        let validated = try await pollUntil {
            !store.connectionRecoveryOwner.isActive
        }
        #expect(validated, "the swap must settle through subscription validation")
        #expect(!store.connectionRecoveryFailed)

        // The gap probe armed at swap commit resolves on the first event the
        // replacement delivers, emitting roaming.swap gap_ms=… to the ring.
        #expect(store.roamingSwapGapProbe != nil)
        let newSubscribed = try await pollUntil {
            await router.count(of: "mobile.events.subscribe") > subscribesBeforeSwap
        }
        #expect(newSubscribed)
        let replacementTransport = try #require(factory.transport(at: 1))
        await replacementTransport.deliver(try renderGridEventFrame(
            surfaceID: "live-terminal",
            seq: 7,
            text: "after-swap"
        ))
        let gapResolved = try await pollUntil {
            store.roamingSwapGapProbe == nil
        }
        #expect(gapResolved, "the first event on the replacement must resolve the gap metric")
    }

    @Test func failedReplacementLeavesServingRelaySessionUntouched() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let factory = RoamingTransportFactory(router: router)
        let store = try await makeRelayConnectedStore(
            router: router,
            factory: factory,
            clock: clock
        )
        let servingClient = try #require(store.remoteClient)
        let servingTransport = try #require(factory.transport(at: 0))

        // Every dial on the new path refuses: the pipelined subscribe's
        // dial AND the exchange's retry dial, exactly like a dead path.
        factory.setPathDown()
        store.recoverMobileConnection(trigger: .networkChange)

        let attemptSettled = try await pollUntil {
            factory.transportCount() >= 2
                && !store.connectionRecoveryOwner.isActive
        }
        #expect(attemptSettled, "the failed roaming attempt must settle")
        #expect(store.remoteClient === servingClient,
                "a failed replacement must not displace the serving client")
        #expect(store.connectionState == .connected)
        #expect(!store.isRecoveringConnection)
        #expect(!store.connectionRecoveryFailed,
                "no failure banner may appear while the old session still serves")
        #expect(await !servingTransport.isClosedForTesting())
        #expect(store.roamingSwapGapProbe == nil)
        // The surviving session still answers: the exact terminal the user is
        // watching keeps working.
        #expect(await store.reloadWorkspaceListFromMac())
    }

    @Test func servingSessionDeathMidDialEscalatesWhenReplacementFails() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let factory = RoamingTransportFactory(router: router)
        let store = try await makeRelayConnectedStore(
            router: router,
            factory: factory,
            clock: clock
        )
        let servingTransport = try #require(factory.transport(at: 0))

        factory.parkPath()
        store.recoverMobileConnection(trigger: .networkChange)
        let dialStarted = try await pollUntil { factory.transportCount() >= 2 }
        #expect(dialStarted)

        // The old session dies while the replacement is still dialing: the
        // in-flight dial is the recovery, and the UI stops pretending the
        // connection is healthy.
        await servingTransport.close()
        let deathObserved = try await pollUntil { store.isRecoveringConnection }
        #expect(deathObserved,
                "old-session death mid-dial must surface reconnecting UI")
        #expect(store.connectionRecoveryOwner.isRedialingOrValidating,
                "the roaming dial keeps owning recovery after the old session dies")

        // The path then settles DOWN, so the replacement fails too (every
        // dial, including the exchange's retry): recovery escalates to the
        // ordinary teardown + automatic retry instead of leaving a dead
        // session published as connected.
        await factory.resolvePath(up: false)
        let escalated = try await pollUntil {
            store.connectionState == .disconnected && store.connectionRecoveryFailed
        }
        #expect(escalated,
                "double failure must resolve to disconnected with a failed attempt")
        #expect(store.automaticReconnectRetryTask != nil,
                "escalation must arm the automatic retry loop")
    }

    @Test func servingSessionDeathMidDialStillSwapsToAdmittedReplacement() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let factory = RoamingTransportFactory(router: router)
        let store = try await makeRelayConnectedStore(
            router: router,
            factory: factory,
            clock: clock
        )
        let servingClient = try #require(store.remoteClient)
        let servingTransport = try #require(factory.transport(at: 0))

        factory.parkPath()
        store.recoverMobileConnection(trigger: .networkChange)
        let dialStarted = try await pollUntil { factory.transportCount() >= 2 }
        #expect(dialStarted)

        await servingTransport.close()
        let deathObserved = try await pollUntil { store.isRecoveringConnection }
        #expect(deathObserved)

        await factory.resolvePath(up: true)
        let swapped = try await pollUntil {
            store.connectionState == .connected
                && store.remoteClient != nil
                && store.remoteClient !== servingClient
        }
        #expect(swapped,
                "an admitted replacement still completes the swap after the old session died")
        let settled = try await pollUntil {
            !store.connectionRecoveryOwner.isActive
        }
        #expect(settled)
        #expect(!store.connectionRecoveryFailed)
    }

    /// Production invariant, pinned: adoption is gated ONLY by the
    /// workspace-list + authenticated host-status exchange (and the identity
    /// and build-compatibility checks it feeds), never by the settlement of
    /// the connect-time pipelined `mobile.events.subscribe`. A host that
    /// rejects the pipelined subscribe must not block (or fail) the roaming
    /// swap; the post-adoption sequential subscribe remains the fallback and
    /// still completes the swap's validation phase.
    @Test func pipelinedSubscribeFailureDoesNotGateRoamingSwapAdoption() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let factory = RoamingTransportFactory(router: router)
        let store = try await makeRelayConnectedStore(
            router: router,
            factory: factory,
            clock: clock
        )
        let servingClient = try #require(store.remoteClient)

        // Fail exactly the replacement's pipelined subscribe on the wire;
        // every other request (the adoption exchange, the fallback
        // sequential subscribe) answers normally.
        let subscribesBefore = await router.count(of: "mobile.events.subscribe")
        await router.failSubscribeRequest(number: subscribesBefore + 1)
        store.recoverMobileConnection(trigger: .networkChange)

        let swapped = try await pollUntil {
            store.remoteClient != nil && store.remoteClient !== servingClient
        }
        #expect(swapped,
                "a rejected pipelined subscribe must not gate the adoption exchange")
        #expect(store.connectionState == .connected)
        let validated = try await pollUntil {
            !store.connectionRecoveryOwner.isActive
        }
        #expect(validated,
                "the fallback sequential subscribe must still complete swap validation")
        #expect(!store.connectionRecoveryFailed)
        let fallbackSubscribed = try await pollUntil {
            await router.count(of: "mobile.events.subscribe") >= subscribesBefore + 2
        }
        #expect(fallbackSubscribed,
                "the failed pipelined subscribe falls back to the sequential subscribe")
    }
}
