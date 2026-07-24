import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAbandonedConnectTests {
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
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func connectTimeoutDoesNotPoisonLaterRetryOnSameClient() async throws {
        let transport = FirstConnectHangsThenSucceedsTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59125)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
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
            abandonedConnectCleanupTimeoutNanoseconds: 1_000_000
        )
        let first = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "first",
            ],
            id: "first-connect-timeout"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "second",
            ],
            id: "second-after-connect-timeout"
        )

        do {
            _ = try await client.sendRequest(first)
            Issue.record("Expected first RPC request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        #expect(await transport.connectCount() == 1)
        #expect(await transport.waitUntilFirstAttemptClosed())

        var retryData: Data?
        for _ in 0..<200 {
            do {
                retryData = try await client.sendRequest(second)
                break
            } catch MobileShellConnectionError.requestTimedOut {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let data = try #require(retryData)
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(await transport.connectCount() == 2)
        #expect(try await transport.sentRequests().map(\.id) == ["second-after-connect-timeout"])
    }

    @Test func connectCancellationErrorDoesNotPoisonLaterRetryOnSameClient() async throws {
        let transport = FirstConnectCancellationThenSucceedsTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59133)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
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
        let first = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "first",
            ],
            id: "first-connect-cancellation"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "second",
            ],
            id: "second-after-connect-cancellation"
        )

        do {
            _ = try await client.sendRequest(first)
            Issue.record("Expected first RPC request to throw CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let data = try await client.sendRequest(second)
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(await transport.connectCount() == 2)
        #expect(try await transport.sentRequests().map(\.id) == ["second-after-connect-cancellation"])
    }

    @Test func repeatedConnectTimeoutsDoNotFanOutWhileCleanupIsStuck() async throws {
        let transport = CancellationIgnoringConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59127)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
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

        for id in ["stuck-connect-1", "stuck-connect-2", "stuck-connect-3"] {
            let request = try MobileCoreRPCClient.requestData(
                method: "terminal.input",
                params: [
                    "workspace_id": "workspace-main",
                    "terminal_id": "terminal-main",
                    "text": id,
                ],
                id: id
            )
            do {
                _ = try await client.sendRequest(request)
                Issue.record("Expected \(id) to time out")
            } catch MobileShellConnectionError.requestTimedOut {
            } catch {
                Issue.record("Expected requestTimedOut for \(id), got \(error)")
            }
        }

        #expect(await transport.connectCount() == 1)
        #expect(await transport.waitUntilCloseCount(1))
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func repeatedConnectCancellationsDoNotFanOutWhileCleanupIsStuck() async throws {
        let transport = CancellationIgnoringConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59128)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
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

        let cancelledRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "cancelled-connect-1",
            ],
            id: "cancelled-connect-1"
        )
        let task = Task {
            try await client.sendRequest(cancelledRequest)
        }

        #expect(await transport.waitUntilConnectCount(1))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled-connect-1 to throw CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError for cancelled-connect-1, got \(error)")
        }

        for id in ["cancelled-connect-2", "cancelled-connect-3"] {
            let retryRequest = try MobileCoreRPCClient.requestData(
                method: "terminal.input",
                params: [
                    "workspace_id": "workspace-main",
                    "terminal_id": "terminal-main",
                    "text": id,
                ],
                id: id
            )
            do {
                _ = try await client.sendRequest(retryRequest)
                Issue.record("Expected \(id) to be rejected while cancelled connect cleanup is stuck")
            } catch MobileShellConnectionError.requestTimedOut {
            } catch {
                Issue.record("Expected requestTimedOut for \(id), got \(error)")
            }
        }

        #expect(await transport.connectCount() == 1)
        #expect(await transport.waitUntilCloseCount(1))
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func lateSuccessfulAbandonedConnectIsClosedAfterCleanupTimeout() async throws {
        let transport = CancellationIgnoringConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59131)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
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
                "text": "late-connect",
            ],
            id: "late-connect"
        )

        do {
            _ = try await client.sendRequest(request)
            Issue.record("Expected late-connect to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        #expect(await transport.waitUntilCloseCount(1))
        await transport.releaseConnects()
        #expect(await transport.waitUntilCloseCount(2))
    }

    @Test func abandonedConnectCleanupCountsCandidateCloseTimeoutBeforeRetry() async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = "debugLoopback|test|127.0.0.1:59135"
        let lease = try #require(await registry.beginConnect(key: key))
        let transport = HangingCloseTransport()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: { transport }
        )

        await session.startAbandonedConnectionCleanup(
            task: Task { transport },
            lease: lease,
            tracksRouteGate: true,
            cleanupTimeoutNanoseconds: 1_000_000_000,
            lateCloseTimeoutNanoseconds: 1_000_000
        )
        await transport.waitUntilCloseStarted()

        var blockedRetryObserved = false
        for _ in 0..<20 {
            if await registry.beginConnect(key: key) == nil {
                blockedRetryObserved = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(blockedRetryObserved)

        var retryLease: MobileRPCConnectAttemptLease?
        for _ in 0..<200 {
            retryLease = await registry.beginConnect(key: key)
            if retryLease != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(retryLease != nil)
        await registry.clearFinishedConnect(lease: retryLease)
    }

    @Test func abandonedConnectGateCapsTimedOutCleanupRetries() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = "debugLoopback|test|127.0.0.1:59129"

        let firstLease = await registry.beginConnect(key: key)
        #expect(firstLease != nil)
        #expect(await registry.beginConnect(key: key) == nil)
        await registry.markAbandoned(lease: firstLease)
        await registry.clearTimedOutAbandonedCleanup(lease: firstLease)

        let secondLease = await registry.beginConnect(key: key)
        #expect(secondLease != nil)
        await registry.markAbandoned(lease: secondLease)
        await registry.clearTimedOutAbandonedCleanup(lease: secondLease)
        #expect(await registry.beginConnect(key: key) == nil)

        await registry.clearFinishedConnect(lease: secondLease)
        #expect(await registry.beginConnect(key: key) != nil)
    }

    @Test func abandonedConnectHardGateExpiresAfterBoundedReset() async throws {
        let registry = MobileRPCConnectAttemptRegistry(hardGateResetNanoseconds: 0)
        let key = "debugLoopback|test|127.0.0.1:59133"

        let firstLease = await registry.beginConnect(key: key)
        #expect(firstLease != nil)
        await registry.markAbandoned(lease: firstLease)
        await registry.clearTimedOutAbandonedCleanup(lease: firstLease)

        let secondLease = await registry.beginConnect(key: key)
        #expect(secondLease != nil)
        await registry.markAbandoned(lease: secondLease)
        await registry.clearTimedOutAbandonedCleanup(lease: secondLease)
        #expect(await registry.beginConnect(key: key) != nil)
    }

    @Test func finishedReleasedConnectResetsRetryBudgetBeforeNextAttempt() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = "debugLoopback|test|127.0.0.1:59132"

        let firstLease = await registry.beginConnect(key: key)
        #expect(firstLease != nil)
        await registry.markAbandoned(lease: firstLease)
        await registry.clearTimedOutAbandonedCleanup(lease: firstLease)
        await registry.clearFinishedConnect(lease: firstLease)

        let secondLease = await registry.beginConnect(key: key)
        #expect(secondLease != nil)
        await registry.markAbandoned(lease: secondLease)
        await registry.clearTimedOutAbandonedCleanup(lease: secondLease)

        #expect(await registry.beginConnect(key: key) != nil)
    }

    @Test func connectAttemptLeaseOnlyReleasesMatchingRouteReservation() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = "debugLoopback|test|127.0.0.1:59130"

        let firstLease = await registry.beginConnect(key: key)
        #expect(firstLease != nil)
        #expect(await registry.beginConnect(key: key) == nil)

        let otherLease = await registry.beginConnect(key: "\(key)-other")
        await registry.clearFinishedConnect(lease: otherLease)
        #expect(await registry.beginConnect(key: key) == nil)

        await registry.recordSuccessfulConnect(lease: firstLease)
        #expect(await registry.beginConnect(key: key) != nil)
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
        #expect(try await transport.sentRequests().isEmpty)
    }

}
