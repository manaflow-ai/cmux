import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Shared fixtures for the render-grid liveness watchdog tests
// (MobileShellRenderGridLivenessTests.swift): injected clock, scripted
// host router, transport mocks, and the connected-store builder.

// MARK: - Injected clock

final class TestClock: @unchecked Sendable {
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

struct LivenessTestRuntime: MobileSyncRuntime {
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
actor LivenessHostRouter {
    struct RecordedRequest: Sendable {
        var method: String?
        var topics: [String]?
    }

    private var recorded: [RecordedRequest] = []
    private var hostStatusRequestCount = 0
    private var heldHostStatusRequestNumbers: Set<Int> = []
    private var subscribeRequestCount = 0
    private var heldSubscribeRequestNumbers: Set<Int> = []
    private var holdSubscribe = false
    private var hasActiveSubscription = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var capabilities = ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"]
    private var replayTexts: [String] = []

    func record(method: String?, topics: [String]?) {
        recorded.append(RecordedRequest(method: method, topics: topics))
    }

    func count(of method: String) -> Int {
        recorded.filter { $0.method == method }.count
    }

    func topics(for method: String) -> [[String]] {
        recorded.compactMap { request in
            guard request.method == method else { return nil }
            return request.topics
        }
    }

    func setCapabilities(_ capabilities: [String]) {
        self.capabilities = capabilities
    }

    func enqueueReplayTexts(_ texts: [String]) {
        replayTexts.append(contentsOf: texts)
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

    /// Hold the Nth `mobile.events.subscribe` request (1-based) forever,
    /// modeling a dead push path whose probe never completes.
    func holdSubscribeRequest(number: Int) {
        heldSubscribeRequestNumbers.insert(number)
    }

    /// Forget the host-side registration, modeling a lost subscription behind
    /// a live RPC channel: the next subscribe reports
    /// `already_subscribed: false`.
    func dropSubscription() {
        hasActiveSubscription = false
    }

    /// Resume every held request so parked continuations do not leak past the
    /// end of the test.
    func releaseAllHeld() {
        holdSubscribe = false
        heldHostStatusRequestNumbers = []
        heldSubscribeRequestNumbers = []
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
                "capabilities": capabilities,
            ])
        case "mobile.events.subscribe":
            subscribeRequestCount += 1
            if holdSubscribe || heldSubscribeRequestNumbers.contains(subscribeRequestCount) {
                await park()
                return nil
            }
            let alreadySubscribed = hasActiveSubscription
            hasActiveSubscription = true
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": alreadySubscribed,
            ])
        case "mobile.terminal.replay":
            guard !replayTexts.isEmpty else {
                return try? Self.resultFrame(id: id, result: [:])
            }
            let text = replayTexts.removeFirst()
            return try? Self.resultFrame(id: id, result: [
                "data_b64": Data(text.utf8).base64EncodedString(),
            ])
        case "mobile.events.unsubscribe", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        case "terminal.input":
            return try? Self.resultFrame(id: id, result: [
                "terminal_seq": 100,
            ])
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
final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: LivenessTransport?

    func set(_ transport: LivenessTransport) {
        lock.withLock { self.transport = transport }
    }

    func get() -> LivenessTransport? {
        lock.withLock { transport }
    }
}

struct LivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}

actor LivenessTransport: CmxByteTransport {
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
final class OutputCollector {
    private(set) var lines: [String] = []
    private(set) var viewportPolicies: [MobileTerminalOutputViewportPolicy?] = []
    private var task: Task<Void, Never>?

    func mount(store: MobileShellComposite, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                self?.lines.append(String(decoding: chunk.data, as: UTF8.self))
                self?.viewportPolicies.append(chunk.viewportPolicy)
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
            }
        }
    }

    func unmount() {
        task?.cancel()
        task = nil
    }
}

func makeTicket(clock: TestClock) throws -> CmxAttachTicket {
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
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: clock.now.addingTimeInterval(3600)
    )
}

func attachURL(for ticket: CmxAttachTicket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(ticket)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"
}

func renderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true
) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        full: full,
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(
                row: 0,
                column: 0,
                styleID: 0,
                text: text
            ),
        ],
        activeScreen: activeScreen
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

func terminalBytesEventFrame(surfaceID: String, seq: UInt64, text: String) throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.bytes",
        "payload": [
            "surface_id": surfaceID,
            "seq": seq,
            "data_b64": Data(text.utf8).base64EncodedString(),
        ],
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

func emptyRenderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    activeScreen: MobileTerminalRenderGridFrame.Screen,
    full: Bool = false
) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        full: full,
        rowSpans: [],
        activeScreen: activeScreen
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
func pollUntil(
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
func makeConnectedStore(
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
