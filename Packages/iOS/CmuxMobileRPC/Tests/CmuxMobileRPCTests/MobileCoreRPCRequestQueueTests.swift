import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCRequestQueueTests {
    @Test func timedOutQueuedSameIDRetryIsNotConsumedByOldTombstone() async throws {
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59133)
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
            id: "first-blocking-send"
        )
        let retryID = "same-id-retry"
        let timedOutQueued = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "old"],
            id: retryID
        )
        let retryQueued = try MobileCoreRPCClient.requestData(
            method: "workspace.create",
            params: ["title": "retry"],
            id: retryID
        )

        let firstTask = Task {
            try await client.sendRequest(firstRequest)
        }
        let firstSent = try await transport.waitForSentRequestCount(1)
        #expect(firstSent.map(\.id) == ["first-blocking-send"])

        let timedOutTask = Task {
            try await client.sendRequest(timedOutQueued, timeoutNanoseconds: 10_000_000)
        }
        do {
            _ = try await timedOutTask.value
            Issue.record("Expected queued request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        let retryTask = Task {
            try await client.sendRequest(retryQueued, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        await transport.releaseFirstSend()
        let sent = try await transport.waitForSentRequestCount(2)
        #expect(sent.map(\.id) == ["first-blocking-send", retryID])

        retryTask.cancel()
        firstTask.cancel()
        _ = try? await retryTask.value
        _ = try? await firstTask.value
    }

    @Test func responseTimeoutDoesNotCloseMultiplexedSession() async throws {
        let transport = ResponseTimeoutSurvivalTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59129)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ResponseTimeoutSurvivalTransportFactory(transport: transport),
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
        let timedOut = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "no-response",
            ],
            id: "first-times-out"
        )

        do {
            _ = try await client.sendRequest(timedOut, timeoutNanoseconds: 10_000_000)
            Issue.record("Expected first request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(!(await transport.closed()))

        let second = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "responds",
            ],
            id: "second-after-timeout"
        )
        let data = try await client.sendRequest(second, timeoutNanoseconds: 60 * 1_000_000_000)
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(!(await transport.closed()))
        #expect(try await transport.sentRequests().map(\.id) == ["first-times-out", "second-after-timeout"])
    }

    @Test func duplicateInFlightRequestIDDoesNotOverwriteFirstCaller() async throws {
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59131)
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
                "text": "duplicate",
            ],
            id: "fixed-duplicate-id"
        )

        let firstTask = Task {
            try await client.sendRequest(request)
        }
        let sent = try await transport.waitForSentRequestCount(1)
        #expect(sent.map(\.id) == ["fixed-duplicate-id"])

        do {
            _ = try await client.sendRequest(request, timeoutNanoseconds: 60 * 1_000_000_000)
            Issue.record("Expected duplicate in-flight id to fail")
        } catch MobileShellConnectionError.invalidResponse {
        } catch {
            Issue.record("Expected invalidResponse, got \(error)")
        }
        #expect(try await transport.sentRequests().map(\.id) == ["fixed-duplicate-id"])

        firstTask.cancel()
        await transport.releaseFirstSend()
        do {
            _ = try await firstTask.value
            Issue.record("Expected first duplicate-id request to remain cancellable")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

}
