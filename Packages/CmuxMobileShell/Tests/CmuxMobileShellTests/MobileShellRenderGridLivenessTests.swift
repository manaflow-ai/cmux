import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for the render-grid liveness watchdog false-fire
// (Release-sim bisect, 2026-06-10): the phone logged "render-grid stream
// silent for 10499ms, re-subscribing" every ~10.5s plus "subscribe failed
// reason=start: requestTimedOut" while the Mac demonstrably kept the
// connection healthy. Two defects combined:
//
// 1. The liveness clock was stamped only inside the listener's `for await`
//    consumer loop, which did not start until the `mobile.events.subscribe`
//    ack round-trip completed. Events yielded into the subscription stream
//    during that window were buffered invisibly, so the watchdog read a
//    healthy establishing stream as silence (and its resync then CANCELLED
//    the in-flight subscribe, which surfaces as `requestTimedOut`).
// 2. A healthy idle terminal legitimately pushes no events at all (the Mac
//    dedupes render-grid emits by row signature + stateSeq), so wall-clock
//    silence alone can never distinguish "idle" from "dead". The watchdog
//    needs a bounded host probe before it may declare death.

// MARK: - Injected clock

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init() {
        current = Date()
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

// MARK: - Runtime double

private struct LivenessTestRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date
    var supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var supportsServerPushEvents: Bool = true
    /// Bounded deadline for the watchdog's host liveness probe. Short here so
    /// the dead-stream test does not wait the production default.
    var livenessProbeTimeoutNanoseconds: UInt64 = 200_000_000
}

// MARK: - Scripted host (router + transport)

/// Scripts the Mac side of the persistent RPC connection: answers the
/// connect-time `workspace.list`, the `mobile.host.status` capability and
/// probe requests, `mobile.events.subscribe`, and replay/viewport calls.
/// Individual requests can be held unresolved to model an ack that has not
/// arrived yet (establishment window) or a host that stopped answering
/// (dead stream).
private actor LivenessHostRouter {
    struct RecordedRequest: Sendable {
        var method: String?
        var topics: [String]?
    }

    private var recorded: [RecordedRequest] = []
    private var hostStatusRequestCount = 0
    private var heldHostStatusRequestNumbers: Set<Int> = []
    private var holdSubscribe = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []

    func record(method: String?, topics: [String]?) {
        recorded.append(RecordedRequest(method: method, topics: topics))
    }

    func count(of method: String) -> Int {
        recorded.filter { $0.method == method }.count
    }

    /// Hold every `mobile.events.subscribe` response until released.
    func setHoldSubscribe(_ hold: Bool) {
        holdSubscribe = hold
    }

    /// Hold the Nth `mobile.host.status` request (1-based) forever, modeling
    /// a host that stopped answering on a half-dead transport.
    func holdHostStatusRequest(number: Int) {
        heldHostStatusRequestNumbers.insert(number)
    }

    /// Resume every held request so parked continuations do not leak past the
    /// end of the test.
    func releaseAllHeld() {
        holdSubscribe = false
        heldHostStatusRequestNumbers = []
        let continuations = heldContinuations
        heldContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func response(method: String?, id: String?) async -> Data? {
        switch method {
        case "workspace.list", "mobile.workspace.list":
            return try? Self.resultFrame(id: id, result: [
                "workspaces": [
                    [
                        "id": "live-workspace",
                        "title": "Live Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "live-terminal",
                                "title": "Terminal",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ])
        case "mobile.host.status":
            hostStatusRequestCount += 1
            if heldHostStatusRequestNumbers.contains(hostStatusRequestCount) {
                await park()
                return nil
            }
            return try? Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": ["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"],
            ])
        case "mobile.events.subscribe":
            if holdSubscribe {
                await park()
                return nil
            }
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
            ])
        case "mobile.events.unsubscribe", "mobile.terminal.replay", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

    private func park() async {
        await withCheckedContinuation { continuation in
            heldContinuations.append(continuation)
        }
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["message": message],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}

/// Holds the live transport instance so the test can push unsolicited
/// server-side event frames through the same receive path production uses.
private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: LivenessTransport?

    func set(_ transport: LivenessTransport) {
        lock.withLock { self.transport = transport }
    }

    func get() -> LivenessTransport? {
        lock.withLock { transport }
    }
}

private struct LivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}

private actor LivenessTransport: CmxByteTransport {
    private let router: LivenessHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: LivenessHostRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let method = parsed?["method"] as? String
            let id = parsed?["id"] as? String
            let topics = (parsed?["params"] as? [String: Any])?["topics"] as? [String]
            await router.record(method: method, topics: topics)
            // Answer each request concurrently so one held response cannot
            // head-of-line block later RPCs, matching the Mac host's
            // per-frame response tasks.
            Task { [router, weak self] in
                guard let response = await router.response(method: method, id: id) else {
                    return
                }
                await self?.deliver(response)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Deliver a frame to the client's read loop. Also used by tests to push
    /// unsolicited server-side event envelopes.
    func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}

// MARK: - Test helpers

@MainActor
private final class OutputCollector {
    private(set) var lines: [String] = []
    private var task: Task<Void, Never>?

    func mount(store: MobileShellComposite, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await data in store.terminalOutputStream(surfaceID: surfaceID) {
                self?.lines.append(String(decoding: data, as: UTF8.self))
            }
        }
    }

    func unmount() {
        task?.cancel()
        task = nil
    }
}

private func makeTicket(clock: TestClock) throws -> CmxAttachTicket {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    return try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: clock.now.addingTimeInterval(3600)
    )
}

private func attachURL(for ticket: CmxAttachTicket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(ticket)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"
}

private func renderGridEventFrame(surfaceID: String, seq: UInt64, text: String) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        text: text
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

/// Poll until `condition` is true, bounded at `attempts` x 10ms. Returns the
/// final value so tests can assert both presence and (bounded) absence.
@MainActor
private func pollUntil(
    attempts: Int = 300,
    _ condition: @MainActor () async -> Bool
) async throws -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@MainActor
private func makeConnectedStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    probeTimeoutNanoseconds: UInt64 = 200_000_000
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now },
        livenessProbeTimeoutNanoseconds: probeTimeoutNanoseconds
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    return store
}

// MARK: - Tests

/// The decoupling found by the bisect: events that the transport delivers
/// while the `mobile.events.subscribe` ack is still in flight must reach the
/// real consumer (and therefore the liveness clock), not pile up unconsumed
/// in the subscription stream's buffer behind the ack await.
@MainActor
@Test func renderGridEventsArrivingDuringStartSubscribeAreConsumed() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    await router.setHoldSubscribe(true)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    // The listener has sent its start subscribe; the ack is parked.
    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must request the server-side subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")

    // The Mac pushes a live render-grid event while the subscribe ack is
    // still pending (the server-side subscription from a previous generation
    // keeps pushing across re-subscribes; the ack is an enable handshake,
    // not a delivery precondition).
    let event = try renderGridEventFrame(surfaceID: "live-terminal", seq: 5, text: "live")
    let transport = try #require(box.get())
    await transport.deliver(event)

    let delivered = try await pollUntil { collector.lines.isEmpty == false }
    #expect(
        delivered,
        "render-grid events must be consumed while the start-subscribe ack is in flight; buffering them unconsumed is what made a healthy stream look silent to the liveness watchdog"
    )
    #expect(collector.lines.first?.contains("live") == true)

    await router.releaseAllHeld()
    collector.unmount()
}

/// A healthy idle stream produces zero events (the Mac dedupes unchanged
/// frames), so silence alone must not tear the subscription down. The
/// watchdog must verify with a host probe and stay quiet when the host
/// answers. Without this, the phone re-subscribed and full-grid re-replayed
/// every ~10.5s forever on any idle terminal.
@MainActor
@Test func watchdogDoesNotResubscribeHealthyIdleStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    // Idle past the silence threshold: no events at all, host healthy.
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    // The watchdog may probe the host (mobile.host.status request number 2;
    // number 1 was the listener's transport-capability resolve), and the
    // router answers it. What it must NOT do is restart the subscription.
    let resubscribed = try await pollUntil(attempts: 60) {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(
        resubscribed == false,
        "the watchdog must not re-subscribe a healthy idle stream; the host answered, so silence only means the terminal had nothing to say"
    )

    // The probe outcome must reset the silence window: an immediate second
    // evaluation stays quiet too.
    store.debugRunRenderGridLivenessCheckForTesting()
    let resubscribedAfterRecheck = try await pollUntil(attempts: 30) {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(resubscribedAfterRecheck == false)
    let replayCount = await router.count(of: "mobile.terminal.replay")
    #expect(replayCount == 0, "no sink is mounted and the stream is healthy, so no replay traffic may be generated")
}

/// The watchdog's original purpose (the ~85s silent-death hang) must keep
/// working: silence past the threshold plus a host that stops answering the
/// probe must still tear down and re-subscribe.
@MainActor
@Test func watchdogStillResubscribesGenuinelyDeadStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    // The host stops answering the next host.status (the watchdog's probe on
    // current code's resync path resolves capabilities first, so holding
    // request number 2 models a dead host in both worlds).
    await router.holdHostStatusRequest(number: 2)
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let resubscribed = try await pollUntil(attempts: 600) {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(
        resubscribed,
        "a stream that is silent past the threshold AND whose host stops answering must still be torn down and re-subscribed"
    )
    await router.releaseAllHeld()
}
