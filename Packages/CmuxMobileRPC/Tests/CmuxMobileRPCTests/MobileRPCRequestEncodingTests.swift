import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Encode-shape coverage: the typed `Codable` request structs must produce the
/// exact same JSON wire shape (keys, value types, absent-vs-null optionals) as
/// the retired `[String: Any]` + `JSONSerialization` envelopes they replace.
@Suite struct MobileRPCRequestEncodingTests {
    private func parsedObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func encodedParams(method: String, params: some Encodable) throws -> NSDictionary {
        let data = try MobileCoreRPCClient.requestData(method: method, params: params, id: "req-1")
        let envelope = try parsedObject(data)
        #expect(envelope["id"] as? String == "req-1")
        #expect(envelope["method"] as? String == method)
        #expect(envelope.count == 3)
        return try #require(envelope["params"] as? NSDictionary)
    }

    @Test func parameterlessRequestKeepsEmptyParamsObject() throws {
        let data = try MobileCoreRPCClient.requestData(method: "workspace.create", id: "req-1")
        let parsed = try parsedObject(data)
        #expect(parsed == ["id": "req-1", "method": "workspace.create", "params": [:]] as NSDictionary)
    }

    @Test func workspaceListParamsMatchLegacyScopedShape() throws {
        let params = try encodedParams(
            method: "workspace.list",
            params: MobileWorkspaceListParams(workspaceID: "ws-1", terminalID: "t-1")
        )
        #expect(params == ["workspace_id": "ws-1", "terminal_id": "t-1"] as NSDictionary)
    }

    @Test func workspaceListParamsOmitAbsentScopeKeys() throws {
        let params = try encodedParams(
            method: "workspace.list",
            params: MobileWorkspaceListParams()
        )
        #expect(params == [:] as NSDictionary)
    }

    @Test func terminalCreateParamsMatchLegacyShape() throws {
        let params = try encodedParams(
            method: "terminal.create",
            params: MobileTerminalCreateParams(workspaceID: "ws-1")
        )
        #expect(params == ["workspace_id": "ws-1"] as NSDictionary)
    }

    @Test func terminalInputParamsMatchLegacyShapeWithViewport() throws {
        let params = try encodedParams(
            method: "terminal.input",
            params: MobileTerminalInputParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                text: "ls\n",
                clientID: "client-1",
                viewportColumns: 80,
                viewportRows: 24
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "text": "ls\n",
            "client_id": "client-1",
            "viewport_columns": 80,
            "viewport_rows": 24,
        ] as NSDictionary)
    }

    @Test func terminalInputParamsOmitUnreportedViewport() throws {
        let params = try encodedParams(
            method: "terminal.input",
            params: MobileTerminalInputParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                text: "x",
                clientID: "client-1"
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "text": "x",
            "client_id": "client-1",
        ] as NSDictionary)
    }

    @Test func terminalScrollParamsPreserveFractionalDelta() throws {
        let params = try encodedParams(
            method: "mobile.terminal.scroll",
            params: MobileTerminalScrollParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                clientID: "client-1",
                deltaLines: -2.5,
                col: 3,
                row: 7
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "client_id": "client-1",
            "delta_lines": -2.5,
            "col": 3,
            "row": 7,
        ] as NSDictionary)
    }

    @Test func terminalMouseParamsMatchLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.terminal.mouse",
            params: MobileTerminalMouseParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                clientID: "client-1",
                col: 3,
                row: 7
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "client_id": "client-1",
            "col": 3,
            "row": 7,
        ] as NSDictionary)
    }

    @Test func terminalViewportReportMatchesLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.terminal.viewport",
            params: MobileTerminalViewportParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                clientID: "client-1",
                viewportColumns: 100,
                viewportRows: 40
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "client_id": "client-1",
            "viewport_columns": 100,
            "viewport_rows": 40,
        ] as NSDictionary)
    }

    @Test func terminalViewportClearMatchesLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.terminal.viewport",
            params: MobileTerminalViewportParams(
                workspaceID: "ws-1",
                surfaceID: "t-1",
                clientID: "client-1",
                clear: true
            )
        )
        #expect(params == [
            "workspace_id": "ws-1",
            "surface_id": "t-1",
            "client_id": "client-1",
            "clear": true,
        ] as NSDictionary)
    }

    @Test func terminalReplayParamsMatchLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.terminal.replay",
            params: MobileTerminalReplayParams(workspaceID: "ws-1", surfaceID: "t-1")
        )
        #expect(params == ["workspace_id": "ws-1", "surface_id": "t-1"] as NSDictionary)
    }

    @Test func eventsSubscribeParamsMatchLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.events.subscribe",
            params: MobileEventsSubscribeParams(
                streamID: "stream-1",
                topics: ["terminal.bytes", "workspace.changed"]
            )
        )
        #expect(params == [
            "stream_id": "stream-1",
            "topics": ["terminal.bytes", "workspace.changed"],
        ] as NSDictionary)
    }

    @Test func attachTicketCreateParamsMatchLegacyShape() throws {
        let params = try encodedParams(
            method: "mobile.attach_ticket.create",
            params: MobileAttachTicketCreateParams(ttlSeconds: 3600, scope: "mac")
        )
        #expect(params == ["ttl_seconds": 3600, "scope": "mac"] as NSDictionary)
    }

    @Test func jsonValueRoundTripPreservesArbitraryEnvelopes() throws {
        // The client rewrites envelopes (id/auth injection) through
        // MobileRPCJSONValue; the rewrite must be lossless for every JSON shape,
        // unknown keys included.
        let original = Data(#"""
        {"id":"x","method":"m","params":{"a":1,"b":2.5,"c":true,"d":null,"e":["x",2],"f":{"g":"h"}},"extra":42}
        """#.utf8)
        let value = try JSONDecoder().decode(MobileRPCJSONValue.self, from: original)
        let reencoded = try JSONEncoder().encode(value)
        #expect(try parsedObject(reencoded) == parsedObject(original))
    }

    @Test func attachTokenAuthInjectionKeepsEnvelopeShape() async throws {
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59124)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: 60 * 1_000_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket)
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: MobileTerminalInputParams(
                workspaceID: "workspace-main",
                surfaceID: "terminal-main",
                text: "ls",
                clientID: "client-1"
            ),
            id: "input-1"
        )

        let sendTask = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        let recorded = try #require(sent.first)
        #expect(recorded.id == "input-1")
        #expect(recorded.method == "terminal.input")
        #expect(recorded.workspaceID == "workspace-main")
        #expect(recorded.terminalID == "terminal-main")
        #expect(recorded.text == "ls")
        #expect(recorded.hasAuth)
        #expect(recorded.attachToken == "ticket-secret")
        #expect(recorded.stackAccessToken == nil)
        sendTask.cancel()
        _ = try? await sendTask.value
        await transport.close()
    }
}
