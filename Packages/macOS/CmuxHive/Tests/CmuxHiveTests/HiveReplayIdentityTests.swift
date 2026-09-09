import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveReplayIdentityTests {
    @Test(arguments: ["workspace_id", "surface_id"], [false, true])
    func rejectsReplayWithInvalidEnvelopeIdentity(field: String, missing: Bool) async throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "term-1", stateSeq: 1, columns: 20, rows: 5, full: true,
            rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "wrong terminal")]
        )
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            case "mobile.terminal.replay":
                var response: [String: Any] = [
                    "workspace_id": "ws-1", "surface_id": "term-1",
                    "render_grid": (try? frame.jsonObject()) ?? [:],
                ]
                response[field] = missing ? nil : "another-terminal"
                return response
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
        let session = HiveRemoteMacSession(
            runtime: runtime, macDeviceID: "mac-b", displayName: "Test Mac",
            routes: [route], retryDelay: { _ in }, requiresHostIdentity: false
        )
        session.connect()
        try await waitUntil { session.phase == .connected }
        let client = try #require(session.client)
        let terminal = HiveRemoteTerminalSession(
            client: client, workspaceID: "ws-1", terminalID: "term-1",
            retryDelay: { _ in await HiveReconnectBackoff(maximumSeconds: 60).delay(attempt: 6) }
        )
        terminal.attach()
        do {
            try await transport.waitForMethod("mobile.terminal.replay")
            try await waitUntil { terminal.phase == .live || terminal.phase == .reattaching }
            #expect(terminal.phase == .reattaching)
            #expect(!terminal.grid.hasContent)
            #expect(terminal.lastFullFrameBytes == nil)
        } catch {
            terminal.detach()
            await session.disconnect()
            throw error
        }
        terminal.detach()
        await session.disconnect()
    }
}
