import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCClientTests {
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
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(!(await transport.closed()))

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

    @Test func connectTimeoutDoesNotCancelOtherWaiters() async throws {
        let transport = ReleasableConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59130)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ReleasableConnectTransportFactory(transport: transport),
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
                "text": "short",
            ],
            id: "short-connect-timeout"
        )
        let long = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "long",
            ],
            id: "long-connect-waiter"
        )

        let shortTask = Task {
            try await client.sendRequest(short, timeoutNanoseconds: 20_000_000)
        }
        #expect(await transport.waitUntilConnectStarted())
        let longTask = Task {
            try await client.sendRequest(long, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        do {
            _ = try await shortTask.value
            Issue.record("Expected short connect waiter to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(!(await transport.closed()))

        await transport.releaseConnect()
        let data = try await longTask.value
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(!(await transport.closed()))
        #expect(try await transport.sentRequests().map(\.id) == ["long-connect-waiter"])
    }

    @Test func cancellingOneConnectWaiterDoesNotClearOtherWaiters() async throws {
        let transport = ReleasableConnectTransport()
        let session = MobileCoreRPCSession(makeTransport: { transport })
        let first = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "cancelled-connect-waiter"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "surviving-connect-waiter"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000

        let firstTask = Task {
            try await session.send(
                payload: first,
                requestID: "cancelled-connect-waiter",
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await transport.waitUntilConnectStarted())
        let secondTask = Task {
            try await session.send(
                payload: second,
                requestID: "surviving-connect-waiter",
                deadlineUptimeNanoseconds: deadline
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        firstTask.cancel()
        #expect(!(await transport.closed()))
        await transport.releaseConnect()

        do {
            _ = try await firstTask.value
            Issue.record("Expected first connect waiter to throw")
        } catch is CancellationError {
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected CancellationError or requestTimedOut, got \(error)")
        }
        let data = try await secondTask.value
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(!(await transport.closed()))
        #expect(try await transport.sentRequests().map(\.id) == ["surviving-connect-waiter"])
    }

    @Test func cancelledCallerClosesConnectedButUninstalledTransport() async throws {
        let cancellation = ConnectCancellationBox()
        let transport = CancelCallerAfterConnectTransport()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await cancellation.cancelWhenSet()
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "cancel-after-connect"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000
        let task = Task {
            try await session.send(
                payload: request,
                requestID: "cancel-after-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await cancellation.set(task)

        do {
            _ = try await task.value
            Issue.record("Expected caller cancellation to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(await transport.closed())
        #expect(await transport.sendCount == 0)
    }

    @Test func cancelledPostConnectWaiterDoesNotCloseTransportForSurvivor() async throws {
        let cancellation = ConnectCancellationBox()
        let transport = ReleasableConnectTransport()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await cancellation.cancelWhenSet()
            }
        )
        let cancelled = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "cancelled-after-connect"
        )
        let surviving = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "surviving-after-connect"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000

        let cancelledTask = Task {
            try await session.send(
                payload: cancelled,
                requestID: "cancelled-after-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await cancellation.set(cancelledTask)
        #expect(await transport.waitUntilConnectStarted())
        let survivingTask = Task {
            try await session.send(
                payload: surviving,
                requestID: "surviving-after-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        await transport.releaseConnect()

        do {
            _ = try await cancelledTask.value
            Issue.record("Expected cancelled waiter to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        let data = try await survivingTask.value
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(!(await transport.closed()))
        #expect(try await transport.sentRequests().map(\.id) == ["surviving-after-connect"])
    }

    @Test func timedOutRPCClosesSlowConnectionBeforeSendingAuthenticatedRequest() async throws {
        let transport = SlowConnectTimeoutTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59124)
        let runtime = TestMobileSyncRuntime(
            transportFactory: SlowConnectTimeoutTransportFactory(transport: transport),
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
                "text": "stale",
            ],
            id: "stale-input"
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected timed-out RPC request to throw")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        #expect(await transport.waitUntilClosed())
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func callerCancelledRPCClosesSlowConnectionBeforeSendingAuthenticatedRequest() async throws {
        let transport = SlowConnectTimeoutTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59126)
        let runtime = TestMobileSyncRuntime(
            transportFactory: SlowConnectTimeoutTransportFactory(transport: transport),
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
                "text": "cancelled",
            ],
            id: "cancelled-input"
        )
        let task = Task {
            try await client.sendRequest(request)
        }

        #expect(await transport.waitUntilConnectStarted())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled RPC request to throw")
        } catch is CancellationError {
        } catch {
        }

        #expect(await transport.waitUntilClosed())
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(try await transport.sentRequests().isEmpty)
    }

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

    @Test func timedOutStackTokenProviderIsNotStartedAgainForSameClient() async throws {
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

    @Test func cancelledTokenWaitDoesNotPoisonNextTokenRequest() async throws {
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
        for _ in 0..<200 {
            if await tokenProvider.startCount == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            Issue.record("Expected cancelled token waiter to throw cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(try await transport.sentRequests().isEmpty)

        let nextTask = Task {
            try await client.sendRequest(next, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        for _ in 0..<200 {
            if await tokenProvider.startCount == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await tokenProvider.startCount == 2)
        await tokenProvider.release()
        let data = try await nextTask.value
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(try await transport.sentRequests().map(\.id) == ["second-after-timeout"])
    }

    @Test func timedOutOptionalHostStatusTokenDoesNotPoisonRequiredAuth() async throws {
        let tokenProvider = FirstCallHangsTokenProvider()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59128)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
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
        let status = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "status"
        )

        do {
            _ = try await client.sendRequest(status, timeoutNanoseconds: 10_000_000)
            Issue.record("Expected optional host-status token lookup to consume the short request deadline")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await tokenProvider.startCount == 1)

        let input = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "after-status",
            ],
            id: "after-status"
        )
        let inputTask = Task {
            try await client.sendRequest(input)
        }
        let sent = try await transport.waitForSentRequestCount(1)
        #expect(sent.first?.method == "terminal.input")
        #expect(sent.first?.stackAccessToken == "second-token")
        #expect(await tokenProvider.startCount == 2)

        inputTask.cancel()
        _ = try? await inputTask.value
        await tokenProvider.release()
    }

    @Test func workspaceListResponseDecodesSnakeCaseWireShape() throws {
        let json = Data("""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "window_id": "window-1",
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
        #expect(workspace.windowID == "window-1")
        #expect(workspace.isSelected)
        #expect(workspace.terminals.first?.isFocused == true)
        #expect(workspace.terminals.first?.isReady == true)
        let mapped = MobileWorkspacePreview(remote: workspace)
        #expect(mapped.windowID == "window-1")
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

    @Test func workspaceActionsCarryMacWideAttachTicketContext() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessToken: "test-stack-token"
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
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
            method: "workspace.action",
            params: [
                "workspace_id": "workspace-main",
                "action": "mark_read",
            ]
        )
        let task = Task { try await client.sendRequest(request) }
        let sent = try await transport.waitForSentRequestCount(1)
        task.cancel()
        _ = try? await task.value

        let frame = try #require(sent.first)
        #expect(frame.method == "workspace.action")
        #expect(frame.workspaceID == "workspace-main")
        #expect(frame.attachToken == "ticket-secret")
        #expect(frame.stackAccessToken == "test-stack-token")
        #expect(frame.hasAuth)
    }
}
