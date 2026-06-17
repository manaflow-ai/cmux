import CMUXMobileCore
import CmuxMobileRPC
import Foundation
@testable import CmuxMobileShell

// Test doubles for MultiMacWorkspaceAggregatorTests: a runtime whose transport
// factory routes each connection to a per-port scripted Mac, so several Macs
// (distinguished by loopback port) can be fetched at once, including two Macs
// returning identical bare workspace/terminal ids to exercise the collision
// invariant.

/// One scripted Mac's `mobile.workspace.list` answer, plus optional forced
/// failure to model an unreachable/erroring host.
struct ScriptedMacList: Sendable {
    /// Bare workspace ids the Mac reports (each gets one terminal id
    /// `<workspaceID>-t`). Kept Mac-local on purpose so two Macs can collide.
    var workspaceIDs: [String]
    /// When true, every request errors, modeling a host that fails to answer.
    var fails: Bool

    init(workspaceIDs: [String], fails: Bool = false) {
        self.workspaceIDs = workspaceIDs
        self.fails = fails
    }
}

/// Maps loopback port -> scripted Mac. The aggregator opens one client per
/// target; each target uses a distinct port, so the port identifies the Mac.
actor MultiMacScriptedHosts {
    private var byPort: [Int: ScriptedMacList]

    init(byPort: [Int: ScriptedMacList]) {
        self.byPort = byPort
    }

    func setList(port: Int, list: ScriptedMacList) {
        byPort[port] = list
    }

    func response(port: Int, method: String?, id: String?) -> Data? {
        guard let mac = byPort[port] else {
            return try? Self.errorFrame(id: id, message: "no scripted host for port \(port)")
        }
        switch method {
        case "mobile.workspace.list", "workspace.list":
            if mac.fails {
                return try? Self.errorFrame(id: id, message: "scripted failure")
            }
            let workspaces = mac.workspaceIDs.map { workspaceID -> [String: Any] in
                [
                    "id": workspaceID,
                    "title": "WS \(workspaceID)",
                    "is_selected": false,
                    "terminals": [
                        [
                            "id": "\(workspaceID)-t",
                            "title": "Terminal",
                            "is_ready": true,
                            "is_focused": false,
                        ],
                    ],
                ]
            }
            return try? Self.resultFrame(id: id, result: ["workspaces": workspaces])
        default:
            return try? Self.errorFrame(id: id, message: "unexpected method \(method ?? "nil")")
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

struct MultiMacRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date = { Date() }
    var supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var supportsServerPushEvents: Bool = true
    var livenessProbeTimeoutNanoseconds: UInt64 = 200_000_000
}

struct MultiMacTransportFactory: CmxByteTransportFactory {
    let hosts: MultiMacScriptedHosts

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard case let .hostPort(_, port) = route.endpoint else {
            throw MobileShellConnectionError.connectionClosed
        }
        return MultiMacTransport(hosts: hosts, port: port)
    }
}

actor MultiMacTransport: CmxByteTransport {
    private let hosts: MultiMacScriptedHosts
    private let port: Int
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(hosts: MultiMacScriptedHosts, port: Int) {
        self.hosts = hosts
        self.port = port
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
            Task { [hosts, port, weak self] in
                guard let response = await hosts.response(port: port, method: method, id: id) else {
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

    func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}

func loopbackRoute(port: Int) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: port)
    )
}
