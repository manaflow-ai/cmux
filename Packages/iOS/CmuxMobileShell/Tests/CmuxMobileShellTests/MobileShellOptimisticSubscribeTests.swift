import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Connect-time pipelined `mobile.events.subscribe` (the "optimistic
// subscribe"): the connect route loop enqueues the subscribe on the same
// FIFO transport write queue immediately before the workspace-list exchange,
// so both requests ride one held pre-admission batch and live events cost a
// single round trip after admission. These tests drive the REAL connect
// sequence over the scripted transport and count requests/round trips.

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

/// The subscribe must ride the same transport batch as the first
/// workspace-list request: it is on the wire BEFORE any connect response has
/// been released (zero completed round trips), it precedes the
/// workspace-list frame in arrival order, and the whole connect performs
/// exactly ONE subscribe round trip (the post-adoption re-subscribe is
/// replaced by the pipelined acknowledgement).
@MainActor
@Test func connectSubscribeRidesTheInitialRequestBatch() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.holdWorkspaceListRequest(number: 1)
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let url = try attachURL(for: makeTicket(clock: clock))
    let connectTask = Task { await store.connectPairingURL(url) }
    defer {
        Task { await router.releaseAllHeld() }
    }

    // The workspace-list response is parked, so no request round trip has
    // completed, yet the subscribe request must already be on the wire.
    #expect(
        await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1),
        "the subscribe must be sent without waiting for any connect response"
    )
    #expect(
        await router.waitForCount(of: "workspace.list", atLeast: 1),
        "the workspace-list request follows in the same batch"
    )
    let methods = await router.recordedMethods()
    let subscribeIndex = try #require(
        methods.firstIndex(of: "mobile.events.subscribe")
    )
    let workspaceListIndex = try #require(
        methods.firstIndex(of: "workspace.list")
    )
    #expect(
        subscribeIndex < workspaceListIndex,
        "the pipelined subscribe rides AHEAD of the workspace-list request in the same batch"
    )
    #expect(
        await router.count(of: "mobile.host.status") == 0,
        "the exchange's host-status probe must still wait on the workspace-list response"
    )

    await router.releaseAllHeld()
    #expect(await connectTask.value, "scripted connect must succeed")
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy, "the pipelined acknowledgement must complete the subscription handshake")
    // One subscribe round trip for the entire connect: the pipelined ack
    // replaced the post-adoption re-subscribe (the scripted host resolves to
    // the same topic set the optimistic request guessed).
    #expect(await router.count(of: "mobile.events.subscribe") == 1)
}

/// Events the Mac pushes AFTER registering the subscription but BEFORE the
/// phone finishes route adoption must be buffered by the pre-registered
/// listener and consumed once the listener generation starts, not dropped by
/// the session's listener dispatch.
@MainActor
@Test func eventsPushedBeforeRouteAdoptionAreConsumed() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    // Park the exchange's host-status response: the subscribe has been
    // acknowledged (registration installed, events flowing) while route
    // adoption cannot complete yet.
    await router.delayHostStatusRequest(number: 1)
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let url = try attachURL(for: makeTicket(clock: clock))
    let connectTask = Task { await store.connectPairingURL(url) }
    defer {
        Task { await router.releaseAllHeld() }
    }

    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
    #expect(await router.waitForCount(of: "mobile.host.status", atLeast: 1))
    #expect(await router.count(of: "workspace.list") == 1)

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
    #expect(await connectTask.value, "scripted connect must succeed")
    let consumed = try await pollUntil {
        store.caffeineStatus?.enabled == true
    }
    #expect(
        consumed,
        "the event buffered before adoption must be consumed by the adopted listener, not dropped"
    )
}

/// When route adoption fails AFTER the pipelined subscribe was acknowledged,
/// the candidate client's transport must close (the Mac host removes every
/// subscription in its connection-close path) and the pending optimistic
/// subscription must be discarded with the candidate.
@MainActor
@Test func adoptionFailureAfterPipelinedSubscribeClosesTheCandidateTransport() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    // The host authenticates as a DIFFERENT Mac than the ticket's pairing:
    // the route is rejected after the exchange (identity mismatch), which is
    // exactly the "adoption fails after subscribe succeeded" window.
    await router.setHostIdentity(
        deviceID: "other-mac",
        instanceTag: "default",
        displayName: "Other Mac"
    )
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let url = try attachURL(for: makeTicket(clock: clock))
    let connected = await store.connectPairingURL(url)
    #expect(!connected, "an identity-mismatched route must be rejected")

    // One subscribe per candidate client (each rejected route makes one
    // exchange, so workspace-list count == candidate count), never zero and
    // never more than one per candidate.
    let subscribeCount = await router.count(of: "mobile.events.subscribe")
    let candidateCount = await router.count(of: "workspace.list")
    #expect(subscribeCount >= 1, "the rejected candidate had already pipelined its subscribe")
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

/// The multi-request workspace-list loop (unscoped first for an
/// attach-token ticket, then the scoped retry) subscribes once per CLIENT:
/// a failed list request reuses the already-pipelined subscribe instead of
/// enqueueing another.
@MainActor
@Test func workspaceListRetryReusesTheSinglePipelinedSubscribe() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.failWorkspaceListRequest(number: 1)
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    // Direct ticket connect: a pairing-URL round trip strips the attach
    // token, and only an attach-token ticket issues the unscoped-then-scoped
    // request pair whose retry semantics this test pins down.
    let failure = try await store.connect(
        ticket: makeAttachTokenTicket(clock: clock)
    )
    #expect(failure == nil, "the scoped retry must succeed")

    #expect(
        await router.waitForCount(of: "workspace.list", atLeast: 2),
        "the first list failure must retry with the next request"
    )
    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy)
    #expect(
        await router.count(of: "mobile.events.subscribe") == 1,
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
    await router.failSubscribeRequest(number: 1)
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let url = try attachURL(for: makeTicket(clock: clock))
    #expect(await store.connectPairingURL(url), "connect must survive a failed pipelined subscribe")

    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy, "the fallback subscribe must complete the handshake")
    #expect(
        await router.count(of: "mobile.events.subscribe") == 2,
        "the sequential post-adoption subscribe must follow the failed pipelined one"
    )
}

/// A host that resolves to a DIFFERENT subscription request than the
/// optimistic guess (here: a verified-replay host narrowing the first
/// pairing's hybrid-superset guess to render-grid topics) must be corrected
/// by the ordinary idempotent re-subscribe, and a reconnect that knows the
/// learned capabilities must then pipeline the exact request and skip the
/// correction.
@MainActor
@Test func topicMismatchReassertsAndReconnectPipelinesExactly() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setCapabilities([
        "events.v1",
        "terminal.bytes.v1",
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.replay.v1",
    ])
    let store = makeSignedInStore(router: router, box: box, clock: clock)
    let url = try attachURL(for: makeTicket(clock: clock))
    #expect(await store.connectPairingURL(url), "scripted connect must succeed")

    let healthy = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthy)
    // First pairing: hybrid-superset guess, then the corrective narrow.
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 2))
    let firstConnectTopics = await router.topics(for: "mobile.events.subscribe")
    #expect(firstConnectTopics.count == 2)
    #expect(firstConnectTopics.first?.contains("terminal.bytes") == true)
    #expect(
        firstConnectTopics.last.map { Set($0) }
            == Set(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics),
        "the corrective re-subscribe must narrow to the resolved render-grid topics"
    )

    // Reconnect (the production recovery path connects with the ticket
    // directly; a fresh pairing URL clears the learned per-Mac state first):
    // learned capabilities make the pipelined request exact, so the whole
    // reconnect performs ONE subscribe round trip.
    let reconnectFailure = try await store.connect(
        ticket: makeTicket(clock: clock)
    )
    #expect(reconnectFailure == nil, "scripted reconnect must succeed")
    let healthyAgain = try await pollUntil(attempts: 1_000) {
        store.macConnectionStatus == .connected
    }
    #expect(healthyAgain)
    let allTopics = await router.topics(for: "mobile.events.subscribe")
    #expect(
        allTopics.count == 3,
        "the reconnect must add exactly one subscribe (no corrective re-subscribe)"
    )
    #expect(
        allTopics.last.map { Set($0) }
            == Set(MobileShellComposite.TerminalOutputTransport.renderGrid.eventTopics),
        "the reconnect's pipelined subscribe must request the learned exact topics"
    )
}
