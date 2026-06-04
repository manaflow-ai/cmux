import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// A minimal `MobileSyncRuntime` for shell package tests: scripted transport
/// factory, fixed token, injectable clock, and an opt-in push-event flag.
struct TestShellSyncRuntime: MobileSyncRuntime {
    var supportedRouteKinds: [CmxAttachTransportKind]
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String
    var rpcRequestTimeoutNanoseconds: UInt64
    var pairingRequestTimeoutNanoseconds: UInt64
    var now: @Sendable () -> Date
    var supportsServerPushEvents: Bool

    init(
        transportFactory: any CmxByteTransportFactory,
        supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback],
        stackAccessToken: String = "test-stack-token",
        rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
        pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = { stackAccessToken }
        self.stackAccessTokenForceRefresher = { stackAccessToken }
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }
}

/// A parsed snapshot of one RPC request frame for test assertions.
struct RecordedShellRPCRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var surfaceID: String?
    var text: String?
    var topics: [String]?
    var viewportColumns: Int?
    var viewportRows: Int?
    var clear: Bool?

    init(payload: Data) throws {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let params = request["params"] as? [String: Any] ?? [:]
        id = request["id"] as? String
        method = request["method"] as? String
        workspaceID = params["workspace_id"] as? String
        surfaceID = params["surface_id"] as? String ?? params["terminal_id"] as? String
        text = params["text"] as? String
        topics = params["topics"] as? [String]
        viewportColumns = params["viewport_columns"] as? Int
        viewportRows = params["viewport_rows"] as? Int
        clear = params["clear"] as? Bool
    }
}

/// Routes each decoded RPC request to a per-method response and supports
/// unsolicited event pushes, mirroring the Mac host's persistent connection.
protocol ShellTransportRouter: Actor {
    func record(_ request: RecordedShellRPCRequest)
    func sentRequests() -> [RecordedShellRPCRequest]
    func response(for request: RecordedShellRPCRequest) async throws -> Data?
}

struct ShellRouterTransportFactory: CmxByteTransportFactory {
    let router: any ShellTransportRouter
    let pusher: ShellEventPusher

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = ShellRouterTransport(router: router)
        Task { await pusher.attach(transport) }
        return transport
    }
}

/// Test handle that pushes unsolicited event frames into the most recently
/// created transport, simulating Mac-side push events.
actor ShellEventPusher {
    private var transport: ShellRouterTransport?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func attach(_ transport: ShellRouterTransport) {
        self.transport = transport
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func push(_ frame: Data) async {
        if transport == nil {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        await transport?.deliverUnsolicited(frame)
    }
}

actor ShellRouterTransport: CmxByteTransport {
    private let router: any ShellTransportRouter
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: any ShellTransportRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
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
            let request = try RecordedShellRPCRequest(payload: payload)
            await router.record(request)
            // Respond concurrently so a blocked response can't head-of-line
            // block subsequent RPCs on the persistent transport.
            Task { [router, weak self] in
                guard let response = try? await router.response(for: request) else {
                    return
                }
                guard let stamped = try? Self.responseFrame(response, matching: request) else {
                    return
                }
                await self?.deliver(stamped)
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

    func deliverUnsolicited(_ frame: Data) {
        deliver(frame)
    }

    private func deliver(_ response: Data) {
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        } else {
            pendingResponses.append(response)
        }
    }

    /// Re-stamps a scripted response envelope with the request's id so the RPC
    /// session can correlate it.
    private static func responseFrame(_ data: Data, matching request: RecordedShellRPCRequest) throws -> Data {
        guard let requestID = request.id else {
            return data
        }
        var buffer = data
        let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        guard !frames.isEmpty else {
            return data
        }
        var encoded = Data()
        for frame in frames {
            guard var envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                encoded.append(try MobileSyncFrameCodec.encodeFrame(frame))
                continue
            }
            // Event envelopes keep their own identity; only responses correlate.
            if envelope["topic"] == nil {
                envelope["id"] = requestID
            }
            let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
            encoded.append(try MobileSyncFrameCodec.encodeFrame(envelopeData))
        }
        return encoded
    }
}

/// Test collector that mounts a surface's output stream and accumulates each
/// chunk's UTF-8 text, mirroring what a mounted `GhosttySurfaceView` would
/// feed into libghostty.
@MainActor
final class ShellTerminalOutputCollector {
    private(set) var lines: [String] = []
    private var task: Task<Void, Never>?

    func mount(store: MobileShellComposite, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await data in store.terminalOutputStream(surfaceID: surfaceID) {
                self?.lines.append(String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    func unmount() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Frame builders

enum ShellTestFrames {
    static func resultFrame(result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(envelopeData)
    }

    static func errorFrame(code: String? = nil, message: String) throws -> Data {
        var error: [String: Any] = ["message": message]
        if let code {
            error["code"] = code
        }
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "ok": false,
            "error": error,
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(envelopeData)
    }

    static func workspaceListFrame(
        workspaceID: String,
        title: String,
        terminalID: String
    ) throws -> Data {
        try resultFrame(
            result: [
                "workspaces": [
                    [
                        "id": workspaceID,
                        "title": title,
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": terminalID,
                                "title": "Terminal",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        )
    }

    static func hostStatusFrame(renderGrid: Bool) throws -> Data {
        let capabilities = renderGrid
            ? ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"]
            : ["events.v1", "terminal.bytes.v1", "terminal.replay.v1"]
        return try resultFrame(
            result: [
                "terminal_fidelity": renderGrid ? "render_grid" : "ghostty_bytes",
                "capabilities": capabilities,
            ]
        )
    }

    static func terminalReplayFrame(
        surfaceID: String,
        seq: UInt64,
        rawText: String,
        renderGridText: String? = nil
    ) throws -> Data {
        var result: [String: Any] = [
            "workspace_id": "live-workspace",
            "surface_id": surfaceID,
            "seq": NSNumber(value: seq),
            "data_b64": Data(rawText.utf8).base64EncodedString(),
            "columns": 16,
            "rows": 4,
        ]
        if let renderGridText {
            let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: surfaceID,
                stateSeq: seq,
                columns: 16,
                rows: 4,
                text: renderGridText
            )
            result["render_grid"] = try frame.jsonObject()
        }
        return try resultFrame(result: result)
    }

    static func terminalBytesEventFrame(
        surfaceID: String,
        seq: UInt64?,
        text: String
    ) throws -> Data {
        var payload: [String: Any] = [
            "workspace_id": "live-workspace",
            "surface_id": surfaceID,
            "data_b64": Data(text.utf8).base64EncodedString(),
        ]
        if let seq {
            payload["seq"] = NSNumber(value: seq)
        }
        let envelope: [String: Any] = [
            "kind": "event",
            "topic": "terminal.bytes",
            "payload": payload,
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(envelopeData)
    }

    static func terminalRenderGridEventFrame(
        surfaceID: String,
        seq: UInt64,
        text: String
    ) throws -> Data {
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
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        return try MobileSyncFrameCodec.encodeFrame(envelopeData)
    }

    static func attachTicketFrame(route: CmxAttachRoute, workspaceID: String) throws -> Data {
        let ticket = try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            authToken: "ticket-secret"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
        return try resultFrame(result: ["ticket": ticketObject])
    }

    static func attachURL(for ticket: CmxAttachTicket) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(ticket).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"
    }

    static func liveTicket(expiresAt: Date = Date().addingTimeInterval(60)) throws -> CmxAttachTicket {
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
            expiresAt: expiresAt
        )
    }
}

func waitForShellRequestCount(
    _ method: String,
    count: Int,
    router: any ShellTransportRouter
) async throws -> [RecordedShellRPCRequest] {
    var matches: [RecordedShellRPCRequest] = []
    for _ in 0..<300 {
        matches = await router.sentRequests().filter { $0.method == method }
        if matches.count >= count {
            return matches
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return matches
}

@MainActor
func waitForCollectedLineCount(
    _ count: Int,
    collector: ShellTerminalOutputCollector
) async throws {
    for _ in 0..<300 where collector.lines.count < count {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
