import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCTokenTimeoutTests {
    @Test func rpcRequestTimeoutCoversStackTokenAcquisition() async throws {
        let tokenStarted = AsyncFlag()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59125)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                await tokenStarted.set()
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return "late-token"
            },
            rpcRequestTimeoutNanoseconds: 10_000_000
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
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "needs-token",
            ],
            id: "needs-token"
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected slow Stack token provider to be bounded by the RPC timeout")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        #expect(await tokenStarted.isSet())
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func timedOutStackTokenProviderIsNotStartedAgainImmediatelyForSameClient() async throws {
        let tokenProvider = CancellationIgnoringTokenProvider()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59127)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                try await tokenProvider.token()
            },
            rpcRequestTimeoutNanoseconds: 10_000_000
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
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true,
            stackTokenGateResetNanoseconds: 30_000_000_000
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "needs-token",
            ],
            id: "needs-token"
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected first token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected second token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)
        #expect(try await transport.sentRequests().isEmpty)

        await tokenProvider.release()
    }

    @Test func timedOutStackTokenProviderIsNotStartedAgainAcrossSharedGateClients() async throws {
        let tokenProvider = CancellationIgnoringTokenProvider()
        let firstTransport = QueuedCancellationProbeTransport()
        let secondTransport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59129)
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let sharedGate = RPCStackTokenGate(timedOutResetNanoseconds: 30_000_000_000)
        let firstClient = MobileCoreRPCClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: QueuedCancellationProbeTransportFactory(transport: firstTransport),
                stackAccessTokenProvider: { try await tokenProvider.token() },
                rpcRequestTimeoutNanoseconds: 10_000_000
            ),
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true,
            stackTokenGate: sharedGate
        )
        let secondClient = MobileCoreRPCClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: QueuedCancellationProbeTransportFactory(transport: secondTransport),
                stackAccessTokenProvider: { try await tokenProvider.token() },
                rpcRequestTimeoutNanoseconds: 10_000_000
            ),
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true,
            stackTokenGate: sharedGate
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "needs-token",
            ],
            id: "needs-token"
        )

        do {
            _ = try await firstClient.sendRequest(request)
            Issue.record("Expected first token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)

        do {
            _ = try await secondClient.sendRequest(request)
            Issue.record("Expected shared gate retry to be blocked")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)
        #expect(try await firstTransport.sentRequests().isEmpty)
        #expect(try await secondTransport.sentRequests().isEmpty)

        await tokenProvider.release()
    }

    @Test func timedOutStackTokenGateRetriesAfterBoundedReset() async throws {
        let tokenProvider = CancellationIgnoringTokenProvider()
        let gate = RPCStackTokenGate(timedOutResetNanoseconds: 0)

        do {
            _ = try await gate.token(timeoutNanoseconds: 1) {
                try await tokenProvider.token()
            }
            Issue.record("Expected first token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)

        do {
            _ = try await gate.token(timeoutNanoseconds: 1) {
                try await tokenProvider.token()
            }
            Issue.record("Expected reset token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 2)

        do {
            _ = try await gate.token(timeoutNanoseconds: 1) {
                try await tokenProvider.token()
            }
            Issue.record("Expected retry budget to block a third stuck provider")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 2)

        await tokenProvider.release()
        let token = try await waitForReleasedToken(gate: gate, tokenProvider: tokenProvider)
        #expect(token == "released-token")
        #expect(await tokenProvider.startCount == 3)
    }

    @Test func shortTokenTimeoutDoesNotCancelLongerTokenWaiter() async throws {
        let tokenProvider = FirstCallHangsTokenProvider()
        let transport = ResponseTimeoutSurvivalTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59133)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ResponseTimeoutSurvivalTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                try await tokenProvider.token()
            },
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
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let short = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "short-token",
            ],
            id: "short-token-timeout"
        )
        let long = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "long-token",
            ],
            id: "second-after-timeout"
        )

        let shortTask = Task {
            try await client.sendRequest(short, timeoutNanoseconds: 100_000_000)
        }
        for _ in 0..<200 {
            if await tokenProvider.startCount == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let longTask = Task {
            try await client.sendRequest(long, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        do {
            _ = try await shortTask.value
            Issue.record("Expected short token waiter to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)
        #expect(try await transport.sentRequests().isEmpty)

        await tokenProvider.release()
        let data = try await longTask.value
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(await tokenProvider.startCount == 1)
        #expect(try await transport.sentRequests().map(\.id) == ["second-after-timeout"])
    }

    @Test func cancelledTokenWaitDoesNotStartSecondStuckProviderImmediately() async throws {
        let tokenProvider = CancellationIgnoringTokenProvider()
        let transport = ResponseTimeoutSurvivalTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59134)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ResponseTimeoutSurvivalTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                try await tokenProvider.token()
            },
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
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let cancelled = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "cancel-token",
            ],
            id: "cancel-token"
        )
        let next = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "next-token",
            ],
            id: "second-after-timeout"
        )

        let cancelledTask = Task {
            try await client.sendRequest(cancelled, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        await tokenProvider.waitUntilStartCount(1)
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            Issue.record("Expected cancelled token waiter to throw cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(try await transport.sentRequests().isEmpty)

        do {
            _ = try await client.sendRequest(next, timeoutNanoseconds: 60 * 1_000_000_000)
            Issue.record("Expected immediate retry to be blocked by the canceled token gate")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)
        await tokenProvider.release()
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func cancelledStackTokenGateRetriesAfterBoundedReset() async throws {
        let tokenProvider = CancellationIgnoringTokenProvider()
        let gate = RPCStackTokenGate(timedOutResetNanoseconds: 0)

        let first = Task {
            try await gate.token(timeoutNanoseconds: 60 * 1_000_000_000) {
                try await tokenProvider.token()
            }
        }
        await tokenProvider.waitUntilStartCount(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await tokenProvider.startCount == 1)

        do {
            _ = try await gate.token(timeoutNanoseconds: 1) {
                try await tokenProvider.token()
            }
            Issue.record("Expected reset token request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 2)

        do {
            _ = try await gate.token(timeoutNanoseconds: 1) {
                try await tokenProvider.token()
            }
            Issue.record("Expected retry budget to block a third stuck provider")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 2)

        await tokenProvider.release()
        let token = try await waitForReleasedToken(gate: gate, tokenProvider: tokenProvider)
        #expect(token == "released-token")
        #expect(await tokenProvider.startCount == 3)
    }

    private func waitForReleasedToken(gate: RPCStackTokenGate, tokenProvider: CancellationIgnoringTokenProvider) async throws -> String {
        for _ in 0..<200 {
            do {
                return try await gate.token(timeoutNanoseconds: 1) {
                    try await tokenProvider.token()
                }
            } catch MobileShellConnectionError.requestTimedOut {
                await Task.yield()
            }
        }
        throw MobileShellConnectionError.requestTimedOut
    }

}
