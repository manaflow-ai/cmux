import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Connect-time pipelined `mobile.events.subscribe` (the "optimistic
// subscribe"): once a Mac's capabilities are learned, a reconnect enqueues
// the exact subscribe on the same FIFO transport write queue immediately
// before the workspace-list exchange, so both requests ride one held
// pre-admission batch and live events cost a single round trip after
// admission. A first pairing has no learned capabilities and keeps today's
// sequential post-adoption subscribe. These tests drive the REAL connect
// sequence over the scripted LivenessHostRouter transport and count
// requests/round trips.

@MainActor
private func makeSignedInStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock
) -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()
    return store
}

/// Ticket whose non-UUID workspace id yields exactly ONE (unscoped)
/// workspace-list request per candidate, keeping request counts exact.
private func makeUnscopedTicket(clock: TestClock) throws -> CmxAttachTicket {
    try makeTicket(clock: clock)
}

private func makeAttachTokenTicket(clock: TestClock) throws -> CmxAttachTicket {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    // A UUID workspace id plus an attach token yields the two-request connect
    // (unscoped list first, scoped list as the retry) whose loop semantics
    // the retry test pins down.
    return try CmxAttachTicket(
        workspaceID: UUID().uuidString,
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: clock.now.addingTimeInterval(3600),
        authToken: "test-attach-token"
    )
}

/// Prime the store with one ordinary connect so the Mac's capabilities are
/// learned (the precondition for the pipelined reconnect subscribe).
@MainActor
private func primeConnectedStore(
    store: MobileShellComposite,
    ticket: CmxAttachTicket
) async throws {
    let failure = try await store.connect(ticket: ticket)
    #expect(failure == nil, "the priming connect must succeed")
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy, "the priming connect must complete its subscription")
}

/// A first pairing must NOT pipeline: the sequential subscribe follows the
/// exchange, built from authenticated capabilities. A reconnect that knows
/// those capabilities pipelines the subscribe onto the same batch as the
/// workspace-list request: it is on the wire BEFORE any of the reconnect's
/// responses is released (zero completed round trips), it precedes the
/// workspace-list frame in arrival order, and the whole reconnect performs
/// exactly ONE subscribe round trip (the pipelined ack replaces the
/// post-adoption re-subscribe).
@MainActor
@Test func reconnectSubscribeRidesTheInitialRequestBatch() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeUnscopedTicket(clock: clock)
    try await primeConnectedStore(store: store, ticket: ticket)

    // First pairing: exactly one subscribe, sent sequentially AFTER the
    // exchange settled (it follows host.status in arrival order).
    #expect(await router.count(of: "mobile.events.subscribe") == 1)
    let primeMethods = await router.recordedMethods()
    let primeSubscribeIndex = try #require(
        primeMethods.firstIndex(of: "mobile.events.subscribe")
    )
    let primeStatusIndex = try #require(
        primeMethods.firstIndex(of: "mobile.host.status")
    )
    #expect(
        primeSubscribeIndex > primeStatusIndex,
        "a first pairing keeps the sequential post-adoption subscribe"
    )
    let hostStatusCountAfterPrime = await router.count(of: "mobile.host.status")

    // Reconnect with the workspace-list response parked: no reconnect round
    // trip has completed, yet the pipelined subscribe is already on the wire,
    // AHEAD of the workspace-list frame.
    await router.holdNextWorkspaceListRequests(count: 1)
    let reconnectTask = Task { try await store.connect(ticket: ticket) }
    defer {
        Task { await router.releaseAllHeld() }
    }
    #expect(
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 2),
        "the reconnect subscribe must be sent without waiting for any response"
    )
    #expect(await router.waitForCount(of: "workspace.list", atLeast: 2))
    let methods = await router.recordedMethods()
    let subscribeIndex = try #require(
        methods.lastIndex(of: "mobile.events.subscribe")
    )
    let workspaceListIndex = try #require(
        methods.lastIndex(of: "workspace.list")
    )
    #expect(
        subscribeIndex < workspaceListIndex,
        "the pipelined subscribe rides AHEAD of the workspace-list request in the same batch"
    )
    #expect(
        await router.count(of: "mobile.host.status") == hostStatusCountAfterPrime,
        "the exchange's host-status probe must still wait on the workspace-list response"
    )

    await router.releaseAllHeld()
    let reconnectFailure = try await reconnectTask.value
    #expect(reconnectFailure == nil, "the scripted reconnect must succeed")
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy, "the pipelined acknowledgement must complete the subscription handshake")
    // One subscribe round trip for the entire reconnect: the pipelined ack
    // replaced the post-adoption re-subscribe (learned capabilities made the
    // optimistic request exactly the resolved request).
    #expect(await router.count(of: "mobile.events.subscribe") == 2)
}

/// Events the Mac pushes AFTER registering the pipelined subscription but
/// BEFORE the phone finishes route adoption must be buffered by the
/// pre-registered listener and consumed once the listener generation starts,
/// not dropped by the session's listener dispatch.
@MainActor
@Test func eventsPushedBeforeRouteAdoptionAreConsumed() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeUnscopedTicket(clock: clock)
    try await primeConnectedStore(store: store, ticket: ticket)
    #expect(store.caffeineStatus == nil)

    // Park the reconnect exchange's host-status response: the pipelined
    // subscribe has been acknowledged (registration installed, events
    // flowing) while route adoption cannot complete yet.
    await router.delayHostStatusRequest(number: 2)
    let reconnectTask = Task { try await store.connect(ticket: ticket) }
    defer {
        Task { await router.releaseAllHeld() }
    }
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 2))
    #expect(await router.waitForCount(of: "mobile.host.status", atLeast: 2))

    // The Mac pushes a state change into the pre-adoption window. Nothing
    // else in this scripted flow writes `caffeineStatus`, so its value is a
    // precise marker for whether THIS buffered event was consumed.
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "caffeine.status.changed",
        "payload": ["enabled": true],
    ]
    let frame = try MobileSyncFrameCodec.encodeFrame(
        JSONSerialization.data(withJSONObject: envelope)
    )
    let transport = try #require(box.get())
    await transport.deliver(frame)
    #expect(store.caffeineStatus == nil, "the event is buffered, not yet consumed")

    await router.releaseAllHeld()
    let reconnectFailure = try await reconnectTask.value
    #expect(reconnectFailure == nil, "the scripted reconnect must succeed")
    let consumed = try await pollUntil {
        store.caffeineStatus?.enabled == true
    }
    #expect(
        consumed,
        "the event buffered before adoption must be consumed by the adopted listener, not dropped"
    )
}

/// When route adoption fails AFTER the pipelined subscribe was acknowledged,
/// every candidate client's transport must close (the Mac host removes every
/// subscription in its connection-close path) and no pending optimistic
/// subscription may outlive its candidate.
@MainActor
@Test func adoptionFailureAfterPipelinedSubscribeClosesTheCandidateTransport() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeUnscopedTicket(clock: clock)
    try await primeConnectedStore(store: store, ticket: ticket)
    let subscribesAfterPrime = await router.count(of: "mobile.events.subscribe")
    let listsAfterPrime = await router.count(of: "workspace.list")

    // The host now authenticates as a DIFFERENT Mac than the ticket's
    // pairing: every reconnect route is rejected after its exchange
    // (identity mismatch), which is exactly the "adoption fails after the
    // subscribe succeeded" window.
    await router.setHostIdentity(
        deviceID: "other-mac",
        instanceTag: "default",
        displayName: "Other Mac"
    )
    var rejected = false
    do {
        let failure = try await store.connect(ticket: ticket)
        rejected = failure != nil
    } catch {
        // Exhausting every route rethrows the last route error.
        rejected = true
    }
    #expect(rejected, "an identity-mismatched route must be rejected")

    // One pipelined subscribe per candidate client (each rejected candidate
    // makes one workspace-list exchange), never more.
    let candidateCount =
        await router.count(of: "workspace.list") - listsAfterPrime
    let subscribeCount =
        await router.count(of: "mobile.events.subscribe") - subscribesAfterPrime
    #expect(candidateCount >= 1)
    #expect(
        subscribeCount == candidateCount,
        "every rejected candidate pipelines exactly one subscribe"
    )
    let transport = try #require(box.get())
    let closed = try await pollUntil {
        await transport.isClosedForTesting()
    }
    #expect(
        closed,
        "rejecting the route must close the candidate transport; the Mac host's connection-close path removes its subscriptions"
    )
    #expect(
        store.optimisticTerminalSubscription == nil,
        "the pending optimistic subscription must not outlive its candidate client"
    )
}

/// The multi-request workspace-list loop (unscoped first for an attach-token
/// ticket, then the scoped retry) subscribes once per CLIENT: a failed list
/// request reuses the already-pipelined subscribe instead of enqueueing
/// another.
@MainActor
@Test func workspaceListRetryReusesTheSinglePipelinedSubscribe() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeAttachTokenTicket(clock: clock)
    try await primeConnectedStore(store: store, ticket: ticket)
    let subscribesAfterPrime = await router.count(of: "mobile.events.subscribe")
    let listsAfterPrime = await router.count(of: "workspace.list")

    // Fail the reconnect's FIRST (unscoped) list request; the scoped retry
    // on the same candidate client must succeed.
    await router.failWorkspaceListRequest(number: listsAfterPrime + 1)
    let failure = try await store.connect(ticket: ticket)
    #expect(failure == nil, "the scoped retry must succeed")

    #expect(
        await router.count(of: "workspace.list") - listsAfterPrime >= 2,
        "the first list failure must retry with the next request"
    )
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy)
    #expect(
        await router.count(of: "mobile.events.subscribe") - subscribesAfterPrime == 1,
        "one subscribe per client: the retried list request reuses the pending pipelined subscribe"
    )
}

/// A failed pipelined subscribe must not regress connect: the post-adoption
/// sequential subscribe still runs and completes the handshake.
@MainActor
@Test func failedPipelinedSubscribeFallsBackToSequentialSubscribe() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeUnscopedTicket(clock: clock)
    try await primeConnectedStore(store: store, ticket: ticket)
    let subscribesAfterPrime = await router.count(of: "mobile.events.subscribe")

    await router.failSubscribeRequest(number: subscribesAfterPrime + 1)
    let failure = try await store.connect(ticket: ticket)
    #expect(failure == nil, "connect must survive a failed pipelined subscribe")

    #expect(
        await router.waitForCount(
            of: "mobile.events.subscribe",
            atLeast: subscribesAfterPrime + 2
        ),
        "the sequential post-adoption subscribe must follow the failed pipelined one"
    )
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy, "the fallback subscribe must complete the handshake")
    #expect(
        await router.count(of: "mobile.events.subscribe") - subscribesAfterPrime == 2
    )
}

/// Capabilities learned from an OLDER host generation can mislead the
/// pipelined request when the Mac upgrades between connects; the ordinary
/// idempotent re-subscribe must correct the registration, and the next
/// reconnect must pipeline the newly learned exact request with no
/// correction.
@MainActor
@Test func staleLearnedCapabilitiesReassertAndNextReconnectPipelinesExactly() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let ticket = try makeUnscopedTicket(clock: clock)
    // Prime against the legacy hybrid host: learned topics include
    // `terminal.bytes`.
    try await primeConnectedStore(store: store, ticket: ticket)
    #expect(await router.count(of: "mobile.events.subscribe") == 1)

    // The Mac "upgrades" to verified replay between connects.
    await router.setCapabilities([
        "events.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.replay.v1",
    ])
    let firstReconnectFailure = try await store.connect(ticket: ticket)
    #expect(firstReconnectFailure == nil)
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy)
    // Stale-guess pipelined subscribe (hybrid topics), then the corrective
    // narrow to the resolved render-grid request.
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 3))
    let topicsAfterUpgrade = await router.topics(for: "mobile.events.subscribe")
    #expect(topicsAfterUpgrade.count == 3)
    #expect(topicsAfterUpgrade[1].contains("terminal.bytes"))
    #expect(
        Set(topicsAfterUpgrade[2])
            == Set(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics),
        "the corrective re-subscribe must narrow to the resolved render-grid topics"
    )

    // Next reconnect: the refreshed capabilities make the pipelined request
    // exact, so the whole reconnect performs ONE subscribe round trip.
    let secondReconnectFailure = try await store.connect(ticket: ticket)
    #expect(secondReconnectFailure == nil)
    let healthyAgain = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthyAgain)
    let allTopics = await router.topics(for: "mobile.events.subscribe")
    #expect(
        allTopics.count == 4,
        "the second reconnect must add exactly one subscribe (no corrective re-subscribe)"
    )
    #expect(
        allTopics.last.map { Set($0) }
            == Set(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics),
        "the reconnect's pipelined subscribe must request the learned exact topics"
    )
}

/// Cold launch has no live connection pool, so the pipelined subscribe's
/// capability snapshot comes from the pairing's PERSISTED set. A stale
/// persisted set (the Mac upgraded to verified replay while this install was
/// not running) must still pipeline, then correct within ONE round trip via
/// the ordinary idempotent re-subscribe, and the refreshed set must be
/// persisted back for the next launch. Mirrors
/// `staleLearnedCapabilitiesReassertAndNextReconnectPipelinesExactly` for the
/// persisted (cross-process) snapshot source.
@MainActor
@Test func stalePersistedCapabilitiesPipelineOnColdLaunchAndCorrectWithinOneRoundTrip() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    // The Mac upgraded to verified replay while the app was not running.
    let upgradedCapabilities = [
        "events.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.replay.v1",
    ]
    await router.setCapabilities(upgradedCapabilities)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pairedStore: any MobilePairedMacStoring = try MobilePairedMacStore(
        databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584),
        priority: 0
    )
    try await pairedStore.upsert(
        macDeviceID: "test-mac",
        displayName: "Test Mac",
        routes: [route],
        instanceTag: "default",
        markActive: true,
        stackUserID: "user-1",
        teamID: nil,
        now: clock.now
    )
    // The snapshot the LAST session learned from the pre-upgrade hybrid host.
    let staleCapabilities: Set<String> = [
        "events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1",
    ]
    try await pairedStore.setLearnedCapabilities(
        macDeviceID: "test-mac",
        instanceTag: "default",
        rawJSON: MobilePairedMac.encodeLearnedCapabilities(staleCapabilities),
        stackUserID: "user-1",
        teamID: nil
    )

    // A fresh composite models the cold launch: nothing pooled, nothing learned
    // in-process, only the persisted snapshot.
    let store = MobileShellComposite(
        runtime: LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        ),
        isSignedIn: true,
        pairedMacStore: pairedStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        reachability: AlwaysOnlineReachability(),
        pairingHintDefaults: UserDefaults(
            suiteName: "cold-launch-persisted-caps-\(UUID().uuidString)"
        )!,
        hiddenMacStore: InMemoryPairedMacHiddenStore()
    )

    let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
    #expect(connected, "the cold-launch reconnect must connect")
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy)

    // The persisted (stale) snapshot pipelined the first subscribe onto the
    // connect batch, ahead of the workspace-list exchange...
    let methods = await router.recordedMethods()
    let subscribeIndex = try #require(methods.firstIndex(of: "mobile.events.subscribe"))
    let workspaceListIndex = try #require(methods.firstIndex(of: "workspace.list"))
    #expect(
        subscribeIndex < workspaceListIndex,
        "the persisted snapshot must pipeline the cold-launch subscribe ahead of the workspace-list request"
    )
    // ...and the stale guess corrected with exactly ONE idempotent
    // re-subscribe round trip.
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 2))
    let topics = await router.topics(for: "mobile.events.subscribe")
    #expect(topics.count == 2, "one pipelined subscribe, one corrective re-subscribe, nothing else")
    #expect(
        topics[0].contains("terminal.bytes"),
        "the pipelined request reflects the stale persisted hybrid snapshot"
    )
    #expect(
        topics.count > 1 && Set(topics[1])
            == Set(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics),
        "the corrective re-subscribe must narrow to the resolved render-grid topics"
    )

    // The corrected set is persisted back so the NEXT cold launch pipelines
    // the exact request.
    let persistedRefreshed = try await pollUntil {
        let row = try? await pairedStore.loadAll(stackUserID: "user-1", teamID: nil).first
        return row.flatMap { $0 }?.learnedCapabilities == Set(upgradedCapabilities)
    }
    #expect(persistedRefreshed, "the learned upgrade must be persisted for the next launch")
    await store.remoteClient?.disconnect()
}
