import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCClientTests {
    @Test func rpcRequestTimeoutCancelsOperationWhenCallerIsCancelled() async throws {
        let started = AsyncFlag()
        let cancelled = AsyncFlag()
        let task = Task {
            try await MobileCoreRPCClient.debugWithRequestTimeout(
                timeoutNanoseconds: 60 * 1_000_000_000
            ) {
                await started.set()
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    return "completed"
                } catch {
                    await cancelled.set()
                    throw error
                }
            }
        }

        for _ in 0..<100 {
            if await started.isSet() {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await started.isSet())

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled RPC timeout wrapper to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        for _ in 0..<100 {
            if await cancelled.isSet() {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await cancelled.isSet())
    }

    @Test func cancelledQueuedRPCIsNotWrittenAfterEarlierSendCompletes() async throws {
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59123)
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
        // Loopback (127.0.0.1) is a Stack-auth-trusted route, so production wires
        // `allowsStackAuthFallback: true` here via the `allSatisfy(routeAllowsStackAuth)`
        // default in MobileShellComposite.connect. Authorized requests now carry the
        // Stack token unconditionally and would otherwise throw `insecureManualRoute`
        // before reaching the transport. This is a transport queue/cancellation test,
        // so enable fallback to match the real trusted-route path.
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let firstRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "first",
            ],
            id: "first-input"
        )
        let queuedRequest = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "queued-workspace"],
            id: "queued-create"
        )

        let firstTask = Task {
            try await client.sendRequest(firstRequest)
        }
        let firstSent = try await transport.waitForSentRequestCount(1)
        #expect(firstSent.map(\.method) == ["terminal.input"])

        let queuedTask = Task {
            try await client.sendRequest(queuedRequest)
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        queuedTask.cancel()
        do {
            _ = try await queuedTask.value
            Issue.record("Expected queued RPC cancellation to throw")
        } catch {
        }

        await transport.releaseFirstSend()
        for _ in 0..<100 {
            if try await transport.sentRequests().count > 1 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let sent = try await transport.sentRequests()
        #expect(sent.map(\.method) == ["terminal.input"])
        firstTask.cancel()
        _ = try? await firstTask.value
    }

    @Test func workspaceListResponseDecodesSnakeCaseWireShape() throws {
        let json = Data("""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "title": "cmux",
              "current_directory": "/Users/test/project",
              "is_selected": true,
              "terminals": [
                {
                  "id": "t-1",
                  "title": "Build",
                  "current_directory": "/Users/test/project",
                  "is_focused": true,
                  "is_ready": true
                }
              ]
            }
          ],
          "created_workspace_id": "ws-1",
          "created_terminal_id": "t-1"
        }
        """.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(json)
        #expect(response.workspaces.count == 1)
        #expect(response.createdWorkspaceID == "ws-1")
        #expect(response.createdTerminalID == "t-1")
        let workspace = try #require(response.workspaces.first)
        #expect(workspace.isSelected)
        #expect(workspace.terminals.first?.isFocused == true)
        #expect(workspace.terminals.first?.isReady == true)
    }

    /// The Mac emits an optional per-workspace `preview` + `preview_at` (latest
    /// notification text + epoch seconds) for the iMessage-style row preview.
    /// Both must decode when present and stay `nil` when an older Mac omits them.
    @Test func workspaceListResponseDecodesOptionalActivityPreview() throws {
        let json = Data("""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "title": "cmux",
              "is_selected": true,
              "preview": "Build finished in 12s",
              "preview_at": 1765000000.5,
              "terminals": []
            },
            {
              "id": "ws-2",
              "title": "older-mac",
              "is_selected": false,
              "terminals": []
            }
          ]
        }
        """.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(json)
        #expect(response.workspaces.count == 2)
        let withPreview = try #require(response.workspaces.first)
        #expect(withPreview.preview == "Build finished in 12s")
        #expect(withPreview.previewAt == 1765000000.5)
        let withoutPreview = try #require(response.workspaces.last)
        #expect(withoutPreview.preview == nil)
        #expect(withoutPreview.previewAt == nil)
    }

    @Test func attachTicketInputDecodesAttachURL() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(600),
            authToken: "tok"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(ticket).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"

        let decoded = try CmxAttachTicketInput.decode(url)
        #expect(decoded.macDeviceID == "mac-1")
        #expect(decoded.routes.first?.kind == .tailscale)
    }
}
