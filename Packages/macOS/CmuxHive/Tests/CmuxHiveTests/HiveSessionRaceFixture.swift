import CMUXMobileCore
import Foundation
@testable import CmuxHive

/// Builds real Hive/RPC sessions over a host whose responses can be released explicitly.
@MainActor
struct HiveSessionRaceFixture {
    let transport: ScriptedHostTransport
    let session: HiveRemoteMacSession

    init(retryDelay: @escaping @Sendable (Int) async -> Void = { _ in }) throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "term-1", stateSeq: 1, columns: 20, rows: 5, full: true,
            rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "ready")]
        )
        transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            case "mobile.terminal.replay":
                return [
                    "workspace_id": "ws-1", "surface_id": "term-1",
                    "render_grid": (try? frame.jsonObject()) ?? [:],
                ]
            default: return [:]
            }
        }
        let runtime = HiveSyncRuntime(
            supportedRouteKinds: [.debugLoopback],
            transportFactory: ScriptedHostTransportFactory(transport: transport),
            stackAccessTokenProvider: { "test-stack-token" },
            stackAccessTokenForceRefresher: { "test-stack-token" },
            rpcRequestTimeoutNanoseconds: 5_000_000_000
        )
        let route = try CmxAttachRoute(
            id: "loopback", kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 8000)
        )
        session = HiveRemoteMacSession(
            runtime: runtime, macDeviceID: "mac-b", displayName: "Test Mac",
            routes: [route], retryDelay: retryDelay, requiresHostIdentity: false
        )
    }

    func connect() async throws {
        session.connect()
        try await waitUntil { session.phase == .connected }
        _ = await session.refreshWorkspaces()
    }
}
