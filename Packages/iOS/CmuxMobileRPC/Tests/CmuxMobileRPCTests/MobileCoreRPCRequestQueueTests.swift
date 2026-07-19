import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCRequestQueueTests {
    @Test func cancelledQueuedSendSkipsAuthorizationWork() async throws {
        let transport = QueuedCancellationProbeTransport()
        let session = MobileCoreRPCSession(makeTransport: { transport })
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        let firstID = "first-blocking-send"
        let cancelledID = "cancelled-queued-send"
        let liveID = "live-queued-send"
        let authorizationRecorder = SendAuthorizationInvocationRecorder()
        let first = Task {
            try await session.send(
                payload: try MobileCoreRPCClient.requestData(method: "workspace.list", id: firstID),
                requestID: firstID,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(try await transport.waitForSentRequestCount(1).map(\.id) == [firstID])

        let cancelled = Task {
            try await session.send(
                payload: try MobileCoreRPCClient.requestData(method: "workspace.list", id: cancelledID),
                requestID: cancelledID,
                deadlineUptimeNanoseconds: deadline,
                sendAuthorizer: { await authorizationRecorder.authorize() }
            )
        }
        #expect(await waitUntilQueued(cancelledID, in: session))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected queued send cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let live = Task {
            try await session.send(
                payload: try MobileCoreRPCClient.requestData(method: "workspace.list", id: liveID),
                requestID: liveID,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await waitUntilQueued(liveID, in: session))

        await transport.releaseFirstSend()
        #expect(try await transport.waitForSentRequestCount(2).map(\.id) == [firstID, liveID])
        #expect(await authorizationRecorder.invocationCount() == 0)

        first.cancel()
        live.cancel()
        _ = try? await first.value
        _ = try? await live.value
        await session.tearDown(error: .connectionClosed)
    }

    @Test func revokedQueuedSendPreservesCancellationWithoutClosingSession() async throws {
        let transport = QueuedCancellationProbeTransport()
        let session = MobileCoreRPCSession(makeTransport: { transport })
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        let firstID = "first-blocking-send"
        let revokedID = "revoked-queued-send"
        let first = Task {
            try await session.send(
                payload: try MobileCoreRPCClient.requestData(method: "workspace.list", id: firstID),
                requestID: firstID,
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(try await transport.waitForSentRequestCount(1).map(\.id) == [firstID])
        let revoked = Task {
            try await session.send(
                payload: try MobileCoreRPCClient.requestData(method: "workspace.list", id: revokedID),
                requestID: revokedID,
                deadlineUptimeNanoseconds: deadline,
                sendAuthorizer: { throw CancellationError() }
            )
        }
        #expect(await waitUntilQueued(revokedID, in: session))

        await transport.releaseFirstSend()
        do {
            _ = try await revoked.value
            Issue.record("Expected revoked queued send to preserve cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(try await transport.sentRequests().map(\.id) == [firstID])
        #expect(!(await transport.closed()))
        first.cancel()
        _ = try? await first.value
        await session.tearDown(error: .connectionClosed)
    }

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
        let client = MobileCoreRPCClient.testClient(
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
        let client = MobileCoreRPCClient.testClient(
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
        let client = MobileCoreRPCClient.testClient(
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

    private func waitUntilQueued(
        _ requestID: String,
        in session: MobileCoreRPCSession
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await session.queuedRequestIDs.contains(requestID) {
                return true
            }
            await Task.yield()
        }
        return await session.queuedRequestIDs.contains(requestID)
    }

}
