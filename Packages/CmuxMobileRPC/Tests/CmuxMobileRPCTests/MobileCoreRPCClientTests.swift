import CMUXMobileCore
import CmuxMobileShellModel
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

    /// The Mac stamps `last_activity_at` on every workspace (falling back to
    /// creation time when there is no notification) and emits `has_unread` for
    /// the row's unread dot. Both must decode when present and degrade safely
    /// (nil timestamp, read state) when an older Mac omits them.
    @Test func workspaceListResponseDecodesLastActivityAndUnread() throws {
        let json = Data("""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "title": "cmux",
              "is_selected": true,
              "last_activity_at": 1765000100.25,
              "has_unread": true,
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
        let stamped = try #require(response.workspaces.first)
        #expect(stamped.lastActivityAt == 1765000100.25)
        #expect(stamped.hasUnread == true)
        let olderMac = try #require(response.workspaces.last)
        #expect(olderMac.lastActivityAt == nil)
        #expect(olderMac.hasUnread == nil)

        // The mapped model treats a missing unread flag as read and carries the
        // optional timestamp through for the row's relative time.
        let mappedStamped = MobileWorkspacePreview(remote: stamped)
        #expect(mappedStamped.hasUnread)
        #expect(mappedStamped.lastActivityAt == Date(timeIntervalSince1970: 1765000100.25))
        let mappedOlder = MobileWorkspacePreview(remote: olderMac)
        #expect(!mappedOlder.hasUnread)
        #expect(mappedOlder.lastActivityAt == nil)
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

    /// A QR-style unscoped ticket (empty ids, no token, no expiry) over the
    /// given route, mirroring what `CmxPairingQRCode.decode` produces.
    private func qrPairingTicket(route: CmxAttachRoute) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            authToken: nil
        )
    }

    /// Sends one `mobile.host.status` probe through a recording transport and
    /// returns the frame that hit the wire. The probe's response is never
    /// produced, so the in-flight task is cancelled once the frame is captured.
    private func sentHostStatusProbe(
        route: CmxAttachRoute,
        stackAccessToken: String?
    ) async throws -> RecordedRPCRequest? {
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: stackAccessToken
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: try qrPairingTicket(route: route),
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value
        #expect(sent.map(\.method) == ["mobile.host.status"])
        return sent.first
    }

    @Test func hostStatusProbeCarriesStackTokenOnTrustedRoute() async throws {
        // The status probe is unauthenticated by design, but the host reports
        // its identity (`mac_device_id`, `mac_display_name`) only to a
        // verified same-account caller, so the client attaches the Stack
        // token whenever it has one and the route is trusted to carry it
        // (Tailscale rides the WireGuard tunnel).
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let probe = try await sentHostStatusProbe(route: route, stackAccessToken: "test-stack-token")
        #expect(probe?.stackAccessToken == "test-stack-token")
        #expect(probe?.attachToken == nil)
    }

    @Test func hostStatusProbeStaysTokenlessWhenTokenUnavailable() async throws {
        // Signed-out probe: a failing token provider must not fail the
        // request. The probe still goes out (reachability needs no auth) and
        // the host simply answers identity-free.
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let probe = try await sentHostStatusProbe(route: route, stackAccessToken: nil)
        #expect(probe?.hasAuth == false)
    }

    @Test func hostStatusProbeNeverSendsStackTokenOnUntrustedRoute() async throws {
        // A manually-entered plain-LAN host is dialed over unencrypted TCP;
        // the account bearer token must never ride it, even opportunistically.
        // The probe itself still goes out tokenless instead of throwing.
        let route = try hostPortRoute(kind: .tailscale, host: "192.168.1.20", port: 58465)
        let probe = try await sentHostStatusProbe(route: route, stackAccessToken: "test-stack-token")
        #expect(probe?.hasAuth == false)
    }
}
