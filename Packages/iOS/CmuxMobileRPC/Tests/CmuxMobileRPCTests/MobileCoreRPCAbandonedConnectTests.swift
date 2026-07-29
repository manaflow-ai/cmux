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

    @Test func abandonedConnectCleanupAllowsOneRecoveryThenCapsDebt()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
            macDeviceID: "test-mac",
            port: 59_135
        )
        guard case let .granted(lease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected initial route admission")
            return
        }
        let transport = HangingCloseTransport()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: { transport }
        )

        await session.startAbandonedConnectionCleanup(
            task: Task { transport },
            lease: lease,
            cleanupTimeoutNanoseconds: 1_000_000_000,
            lateCloseTimeoutNanoseconds: 1_000_000
        )
        await transport.waitUntilCloseStarted()

        var recoveryLease: MobileRPCConnectAttemptLease?
        for _ in 0..<20 {
            if case let .granted(lease) =
                await registry.beginConnect(key: key) {
                recoveryLease = lease
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let retryLease = try #require(recoveryLease)
        let secondCleanup = PhysicalCleanupGate()
        await registry.handOffPhysicalCleanup(lease: retryLease) {
            await secondCleanup.wait()
        }
        #expect(
            await registry.beginConnect(key: key) == .cleanupBlocked
        )
        var sessionCleanupDrained = false
        for _ in 0..<20 {
            if await session.abandonedConnectionCleanupTasks.isEmpty {
                sessionCleanupDrained = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(sessionCleanupDrained)

        await transport.releaseClose()
        await session.waitForTransportDrain()
        #expect(await session.abandonedConnectionCleanupTasks.isEmpty)
        var reopenedLease: MobileRPCConnectAttemptLease?
        for _ in 0..<20 {
            if case let .granted(lease) =
                await registry.beginConnect(key: key) {
                reopenedLease = lease
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(reopenedLease != nil)
        await registry.finishConnect(lease: reopenedLease)
        await secondCleanup.release()
    }

    @Test func successfulRecoveryPreservesOlderPhysicalCleanupDebt()
        async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
            macDeviceID: "test-mac",
            port: 59_129
        )
        let firstCleanup = PhysicalCleanupGate()
        let secondCleanup = PhysicalCleanupGate()

        guard case let .granted(firstLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected first route admission")
            return
        }
        await registry.handOffPhysicalCleanup(lease: firstLease) {
            await firstCleanup.wait()
        }
        guard case let .granted(recoveryLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected one recovery admission")
            return
        }
        await registry.recordSuccessfulConnect(lease: recoveryLease)
        guard case let .granted(laterLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected later admission with one cleanup debt")
            return
        }
        await registry.handOffPhysicalCleanup(lease: laterLease) {
            await secondCleanup.wait()
        }

        #expect(
            await registry.beginConnect(key: key) == .cleanupBlocked
        )
        await firstCleanup.release()
        await secondCleanup.release()
    }

    @Test func timedOutPhysicalCloseIsHandedOffWithoutCancellation()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
            macDeviceID: "test-mac",
            port: 59_128
        )
        guard case let .granted(firstLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected initial route admission")
            return
        }
        let transport = CancellationSensitiveCloseTransport()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: { transport }
        )
        await session.startAbandonedConnectionCleanup(
            task: Task { transport },
            lease: firstLease,
            cleanupTimeoutNanoseconds: 1_000_000_000,
            lateCloseTimeoutNanoseconds: 1_000_000
        )
        await transport.waitUntilCloseStarted()

        var recoveryLease: MobileRPCConnectAttemptLease?
        for _ in 0..<20 {
            if case let .granted(lease) =
                await registry.beginConnect(key: key) {
                recoveryLease = lease
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let secondLease = try #require(recoveryLease)
        let secondCleanup = PhysicalCleanupGate()
        await registry.handOffPhysicalCleanup(lease: secondLease) {
            await secondCleanup.wait()
        }

        #expect(!(await transport.didObserveCloseCancellation()))
        #expect(await registry.beginConnect(key: key) == .cleanupBlocked)

        await transport.releaseClose()
        await secondCleanup.release()
    }

    @Test func connectAttemptLeaseOnlyReleasesMatchingRouteReservation() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
            macDeviceID: "test-mac",
            port: 59_130
        )
        let otherKey = debugConnectAttemptKey(
            macDeviceID: "test-mac-other",
            port: 59_130
        )

        guard case let .granted(firstLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected first route admission")
            return
        }
        #expect(await registry.beginConnect(key: key) == .busy)

        guard case let .granted(otherLease) =
                await registry.beginConnect(key: otherKey) else {
            Issue.record("Expected unrelated route admission")
            return
        }
        await registry.finishConnect(lease: otherLease)
        #expect(await registry.beginConnect(key: key) == .busy)

        await registry.recordSuccessfulConnect(lease: firstLease)
        guard case let .granted(nextLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected released route admission")
            return
        }
        await registry.finishConnect(lease: nextLease)
    }

    @Test func connectAttemptKeySeparatesPeersAndIgnoresIrohHintChurn()
        async throws {
        let identityA = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let identityB = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "b", count: 64)
        )
        let refreshedHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .publicInternet
        )
        let initialRoute = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identityA, pathHints: [])
        )
        let refreshedRoute = try CmxAttachRoute(
            id: "iroh-refreshed",
            kind: .iroh,
            endpoint: .peer(
                identity: identityA,
                pathHints: [refreshedHint]
            )
        )
        let otherPeerRoute = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identityB, pathHints: [])
        )
        let initialKey = MobileRPCConnectAttemptKey(
            route: initialRoute,
            expectedPeerDeviceID: "mac-a"
        )
        let refreshedKey = MobileRPCConnectAttemptKey(
            route: refreshedRoute,
            expectedPeerDeviceID: "mac-a"
        )
        let otherPeerKey = MobileRPCConnectAttemptKey(
            route: otherPeerRoute,
            expectedPeerDeviceID: "mac-b"
        )
        let otherMacKey = MobileRPCConnectAttemptKey(
            route: initialRoute,
            expectedPeerDeviceID: "mac-c"
        )

        #expect(initialKey == refreshedKey)
        #expect(initialKey != otherPeerKey)
        #expect(initialKey != otherMacKey)

        let registry = MobileRPCConnectAttemptRegistry()
        guard case let .granted(initialLease) =
                await registry.beginConnect(key: initialKey) else {
            Issue.record("Expected first peer admission")
            return
        }
        #expect(await registry.beginConnect(key: refreshedKey) == .busy)
        guard case let .granted(otherPeerLease) =
                await registry.beginConnect(key: otherPeerKey) else {
            Issue.record("Expected unrelated peer admission")
            return
        }
        await registry.finishConnect(lease: initialLease)
        await registry.finishConnect(lease: otherPeerLease)
    }

    @Test func cleanupDebtCapSurfacesRestartRequiredError() async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
            macDeviceID: "test-mac",
            port: 59_133
        )
        let firstCleanup = PhysicalCleanupGate()
        let secondCleanup = PhysicalCleanupGate()

        guard case let .granted(firstLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected first route admission")
            return
        }
        await registry.handOffPhysicalCleanup(lease: firstLease) {
            await firstCleanup.wait()
        }
        guard case let .granted(secondLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected recovery route admission")
            return
        }
        await registry.handOffPhysicalCleanup(lease: secondLease) {
            await secondCleanup.wait()
        }
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: {
                Issue.record("Cleanup-blocked route must not allocate transport")
                return SlowConnectTimeoutTransport()
            }
        )

        do {
            _ = try await session.send(
                payload: MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: "cleanup-debt-cap"
                ),
                requestID: "cleanup-debt-cap",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
            Issue.record("Expected cleanup-blocked admission to throw")
        } catch MobileShellConnectionError.routeCleanupBlocked {
        } catch {
            Issue.record("Expected routeCleanupBlocked, got \(error)")
        }

        await firstCleanup.release()
        await secondCleanup.release()
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

private func debugConnectAttemptKey(
    macDeviceID: String,
    port: Int
) -> MobileRPCConnectAttemptKey {
    let route = try! CmxAttachRoute(
        id: "test",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: port)
    )
    return MobileRPCConnectAttemptKey(
        route: route,
        expectedPeerDeviceID: macDeviceID
    )
}

private actor PhysicalCleanupGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
