import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileBrowserRPCDTOTests {
    @Test func frameAckRequestUsesWireKeys() throws {
        let data = try MobileBrowserRPCRequestEncoder().requestData(
            method: "mobile.browser.frame.ack",
            parameters: MobileBrowserFrameAckParameters(panelID: "panel-1", sequence: 42)
        )
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(request["method"] as? String == "mobile.browser.frame.ack")
        #expect(params["panel_id"] as? String == "panel-1")
        #expect(params["seq"] as? UInt64 == 42)
        #expect(params["panelID"] == nil)
    }

    @Test func sharedScrollInputPreservesSnakeCaseWireShape() throws {
        let input = MobileBrowserScrollInput(
            panelID: "panel-2",
            deltaX: 1.5,
            deltaY: -3,
            phase: .momentumChanged,
            x: 10,
            y: 20
        )
        let data = try MobileBrowserRPCRequestEncoder().requestData(
            method: "mobile.browser.input.scroll",
            parameters: input
        )
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["panel_id"] as? String == "panel-2")
        #expect(params["dx"] as? Double == 1.5)
        #expect(params["dy"] as? Int == -3)
        #expect(params["phase"] as? String == "momentum_changed")
    }

    @Test func viewportUpdateUsesFlattenedWireKeys() throws {
        let data = try MobileBrowserRPCRequestEncoder().requestData(
            method: "mobile.browser.viewport",
            parameters: MobileBrowserViewportParameters(
                panelID: "panel-2",
                viewport: MobileBrowserViewport(width: 393, height: 740, scale: 3)
            )
        )
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(request["method"] as? String == "mobile.browser.viewport")
        #expect(params["panel_id"] as? String == "panel-2")
        #expect(params["viewport_width"] as? Int == 393)
        #expect(params["viewport_height"] as? Int == 740)
        #expect(params["viewport_scale"] as? Int == 3)
    }

    @Test func dialogResponseUsesWireKeysAndPreservesSensitiveText() throws {
        let data = try MobileBrowserRPCRequestEncoder().requestData(
            method: "mobile.browser.dialog.respond",
            parameters: MobileBrowserDialogRespondParameters(
                panelID: "panel-2",
                dialogID: "dialog-7",
                buttonID: "sign_in",
                text: "octocat\u{0}secret"
            )
        )
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(request["method"] as? String == "mobile.browser.dialog.respond")
        #expect(params["panel_id"] as? String == "panel-2")
        #expect(params["dialog_id"] as? String == "dialog-7")
        #expect(params["button_id"] as? String == "sign_in")
        #expect(params["text"] as? String == "octocat\u{0}secret")
        #expect(params["panelID"] == nil)
    }

    @Test func commandResponseDecodesMacVariants() throws {
        let ackData = try JSONSerialization.data(withJSONObject: [
            "acked": true,
            "panel_id": "panel-3",
            "seq": 99,
        ])
        let ack = try MobileBrowserCommandResponse.decode(ackData)
        #expect(ack.acknowledged == true)
        #expect(ack.panelID == "panel-3")
        #expect(ack.sequence == 99)

        let stopData = try JSONSerialization.data(withJSONObject: [
            "stopped": true,
            "panel_id": "panel-3",
        ])
        let stop = try MobileBrowserCommandResponse.decode(stopData)
        #expect(stop.stopped == true)
        #expect(stop.panelID == "panel-3")
    }

    @Test func browserListCarriesMatchingWorkspaceTicketContext() async throws {
        let frame = try await recordedRequest(
            method: "mobile.browser.list",
            params: ["workspace_id": "workspace-main"],
            ticketWorkspaceID: "workspace-main"
        )
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
    }

    @Test func panelCommandUsesMacWideTicketContext() async throws {
        let frame = try await recordedRequest(
            method: "mobile.browser.stream.start",
            params: ["panel_id": "panel-1"],
            ticketWorkspaceID: ""
        )
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
    }

    @Test func panelCommandOmitsUnprovableWorkspaceTicketContext() async throws {
        let frame = try await recordedRequest(
            method: "mobile.browser.input.key",
            params: ["panel_id": "panel-1", "key": "return", "modifiers": []],
            ticketWorkspaceID: "workspace-main"
        )
        #expect(frame.attachToken == nil)
        #expect(frame.stackAccessToken == "test-stack-token")
    }

    @Test func viewportUpdateUsesMacWideTicketContext() async throws {
        let frame = try await recordedRequest(
            method: "mobile.browser.viewport",
            params: [
                "panel_id": "panel-1",
                "viewport_width": 393,
                "viewport_height": 740,
                "viewport_scale": 3,
            ],
            ticketWorkspaceID: ""
        )
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
    }

    private func recordedRequest(
        method: String,
        params: [String: Any],
        ticketWorkspaceID: String
    ) async throws -> RecordedRPCRequest {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token"
        )
        let ticket = try CmxAttachTicket(
            workspaceID: ticketWorkspaceID,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        return try #require(sent.first)
    }
}
