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

    // The Stack token fetch can itself hit the network (the SDK refreshes a
    // stale access token), so it must sit under the same per-request deadline
    // as the send: during pairing these requests hold the visible spinner, and
    // a hung refresh outside the deadline waits on the OS-default request
    // timeout (~60s) before the per-request bound even starts. The fake park
    // deliberately IGNORES cancellation: the SDK's mint is not guaranteed to be
    // cancellation-responsive, so the deadline must win by abandoning it
    // (first-yield-wins), not by waiting for a cooperative cancel.
    @Test func hungStackTokenFetchIsBoundedByRequestTimeout() async throws {
        let transport = QueuedCancellationProbeTransport()
        let gate = UncancellableGate()
        let clock = ManualTestClock()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59124)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await gate.wait()
                throw MissingTestStackAccessToken()
            },
            rpcRequestTimeoutNanoseconds: 50_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
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
            allowsStackAuthFallback: true,
            clock: clock
        )
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])

        let sendTask = Task {
            try await client.sendRequest(request)
        }
        // Advance virtual time only once the deadline is actually parked, then
        // cross the 50ms request budget while the token fetch stays hung.
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(50))
        do {
            _ = try await sendTask.value
            Issue.record("Expected the hung token fetch to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        // The deadline fired before auth resolved, so nothing reached the wire.
        #expect(try await transport.sentRequests().isEmpty)
        // Unpark the abandoned fetch so the test leaks no continuation.
        await gate.open()
    }

    // A token fetch that ends in cancellation (the caller was reaped by the
    // route race, superseded, or dismissed) must surface as cancellation, not
    // be remapped into a definitive `.authorizationFailed`: callers treat
    // definitive auth failures as session evidence and would trip the re-auth
    // prompt on a mere cancel.
    @Test func cancelledStackTokenFetchSurfacesAsCancellationNotAuthFailure() async throws {
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59124)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: { throw CancellationError() }
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
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
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected the cancelled token fetch to fail the request")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        // Cancellation aborted auth before anything reached the wire.
        #expect(try await transport.sentRequests().isEmpty)
    }

    // A task group joins every child before returning, so a deadline built on
    // one only delivers when the operation honors cancellation. The deadline
    // must fire even when the operation never does (a stuck SDK call), by
    // abandoning it rather than joining it.
    @Test func requestDeadlineFiresEvenWhenOperationIgnoresCancellation() async throws {
        let gate = UncancellableGate()
        let clock = ManualTestClock()
        let timeoutTask = Task {
            try await MobileCoreRPCClient.debugWithRequestTimeout(
                timeoutNanoseconds: 50_000_000,
                clock: clock
            ) { () -> String in
                await gate.wait()
                return "late"
            }
        }
        // Advance virtual time only once the deadline is actually parked.
        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .milliseconds(50))
        do {
            _ = try await timeoutTask.value
            Issue.record("Expected the deadline to fire")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        await gate.open()
    }

    // The pairing route race cancels losing attempts and joins them before
    // returning the winner, so a losing route whose dial is stuck in an
    // OS-level connect that ignores cancellation must not hold the cancelled
    // attempt (and with it the winner's spinner) until the connect timeout:
    // the cancelled caller has to unblock immediately.
    @Test func callerCancellationUnblocksWhileConnectIsStuckUncancellably() async throws {
        let transport = HungConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59125)
        let runtime = TestMobileSyncRuntime(
            transportFactory: HungConnectTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: 60 * 1_000_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
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
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])

        let task = Task {
            try await client.sendRequest(request)
        }
        for _ in 0..<200 {
            if await transport.connectStarted() {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await transport.connectStarted())

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the cancelled request to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        // Unpark the abandoned dial so the test leaks no continuation.
        await transport.releaseConnect()
    }

    // The first-yield-wins deadline abandons work that ignores cancellation,
    // so the abandoned task can resume long after the caller observed
    // requestTimedOut. If the stuck dial then completes successfully, the
    // resumed task must not carry the request onto the wire: a non-idempotent
    // RPC (terminal input, workspace create) the UI reported as failed would
    // otherwise execute late. The gate is `session.send`'s cancellation check
    // after connection establishment, before the write is registered. Without
    // the gate, suppression rests on the cancellation handler beating the
    // writer to the actor, so this test's red state is racy rather than
    // deterministic; the gate is what makes the behavior deterministic.
    @Test func abandonedRequestNeverSendsAfterLateConnectSuccess() async throws {
        let transport = HungConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59126)
        let runtime = TestMobileSyncRuntime(
            transportFactory: HungConnectTransportFactory(transport: transport),
            rpcRequestTimeoutNanoseconds: 50_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
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
        let request = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "late-create"],
            id: "late-create"
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected the stuck dial to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        // The dial now completes successfully, resuming the abandoned work
        // task inside session.send with its task already cancelled.
        await transport.releaseConnectSuccessfully()
        // Give the abandoned task time to run its course; the caller already
        // observed the timeout, so nothing may reach the wire.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 1_000_000)
            if await transport.sentFrameCount() > 0 {
                break
            }
        }
        #expect(await transport.sentFrameCount() == 0)
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
