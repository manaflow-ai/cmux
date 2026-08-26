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

        for (index, id) in ["stuck-connect-1", "stuck-connect-2", "stuck-connect-3"].enumerated() {
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
                Issue.record("Expected \(id) to fail")
            } catch MobileShellConnectionError.requestTimedOut where index == 0 {
            } catch MobileShellConnectionError.routeCleanupBlocked where index > 0 {
            } catch {
                Issue.record("Expected bounded admission failure for \(id), got \(error)")
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
            } catch MobileShellConnectionError.routeCleanupBlocked {
            } catch {
                Issue.record("Expected routeCleanupBlocked for \(id), got \(error)")
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
        await registry.finishConnect(lease: recoveryLease)
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
            port: 59_130
        )
        let otherKey = debugConnectAttemptKey(
            port: 59_131
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

        await registry.finishConnect(lease: firstLease)
        guard case let .granted(nextLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected released route admission")
            return
        }
        await registry.finishConnect(lease: nextLease)
    }

    @Test func activeRouteAdmissionReportsRouteGatedInsteadOfTimedOut()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(port: 59_134)
        let firstTransport = ReleasableConnectTransport()
        let firstSession = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: { firstTransport }
        )
        let secondSession = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: {
                Issue.record("Gated route must not allocate transport")
                return ReleasableConnectTransport()
            }
        )
        let firstTask = Task {
            try await firstSession.send(
                payload: MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: "active-route-owner"
                ),
                requestID: "active-route-owner",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
        }
        #expect(await firstTransport.waitUntilConnectStarted())

        do {
            _ = try await secondSession.send(
                payload: MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: "active-route-contender"
                ),
                requestID: "active-route-contender",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
            Issue.record("Expected route gate to reject concurrent admission")
        } catch MobileShellConnectionError.connectAttemptGated {
        } catch {
            Issue.record("Expected connectAttemptGated, got \(error)")
        }

        await firstTransport.releaseConnect()
        _ = try await firstTask.value
        await firstSession.tearDown(error: .connectionClosed)
    }

    @Test func connectAttemptKeySeparatesPhysicalEndpoints()
        async throws {
        let firstWebSocketRoute = try CmxAttachRoute(
            id: "websocket-first",
            kind: .websocket,
            endpoint: .url(
                "wss://example.test/mobile?token=first-secret"
            )
        )
        let rotatedWebSocketRoute = try CmxAttachRoute(
            id: "websocket-rotated",
            kind: .websocket,
            endpoint: .url(
                "wss://example.test/mobile?token=second-secret"
            )
        )
        #expect(
            MobileRPCConnectAttemptKey(
                route: firstWebSocketRoute
            )
                == MobileRPCConnectAttemptKey(
                    route: rotatedWebSocketRoute
                )
        )
        let explicitDefaultPortWebSocketRoute = try CmxAttachRoute(
            id: "websocket-explicit-default-port",
            kind: .websocket,
            endpoint: .url(
                "wss://example.test:443/mobile?token=third-secret"
            )
        )
        #expect(
            MobileRPCConnectAttemptKey(
                route: firstWebSocketRoute
            )
                == MobileRPCConnectAttemptKey(
                    route: explicitDefaultPortWebSocketRoute
                )
        )
        let otherWebSocketRoute = try CmxAttachRoute(
            id: "websocket-other-host",
            kind: .websocket,
            endpoint: .url(
                "wss://other.example.test/mobile?token=first-secret"
            )
        )
        #expect(
            MobileRPCConnectAttemptKey(
                route: firstWebSocketRoute
            )
                != MobileRPCConnectAttemptKey(
                    route: otherWebSocketRoute
                )
        )

        let registry = MobileRPCConnectAttemptRegistry()
        let firstKey = MobileRPCConnectAttemptKey(route: firstWebSocketRoute)
        guard case let .granted(firstLease) =
                await registry.beginConnect(key: firstKey) else {
            Issue.record("Expected first endpoint admission")
            return
        }
        #expect(await registry.beginConnect(
            key: MobileRPCConnectAttemptKey(route: rotatedWebSocketRoute)
        ) == .busy)
        guard case let .granted(otherLease) =
                await registry.beginConnect(
                    key: MobileRPCConnectAttemptKey(route: otherWebSocketRoute)
                ) else {
            Issue.record("Expected unrelated endpoint admission")
            return
        }
        await registry.finishConnect(lease: firstLease)
        await registry.finishConnect(lease: otherLease)
    }

    @Test func connectAttemptKeyCanonicalizesEquivalentHostSpellings()
        throws {
        func route(host: String) throws -> CmxAttachRoute {
            try CmxAttachRoute(
                id: host,
                kind: .debugLoopback,
                endpoint: .hostPort(host: host, port: 58_581)
            )
        }

        #expect(
            MobileRPCConnectAttemptKey(route: try route(
                host: "2001:db8:0:0:0:0:0:1"
            ))
                == MobileRPCConnectAttemptKey(route: try route(
                    host: "2001:DB8::1"
                ))
        )
        #expect(
            MobileRPCConnectAttemptKey(route: try route(
                host: "Mac.Example.Test."
            ))
                == MobileRPCConnectAttemptKey(route: try route(
                    host: "mac.example.test"
                ))
        )
        let canonicalIPv4Key = MobileRPCConnectAttemptKey(
            route: try route(host: "127.0.0.1")
        )
        for alias in [
            "127.1",
            "0x7f.0.0.1",
            "0177.0.0.1",
            "2130706433",
        ] {
            #expect(
                MobileRPCConnectAttemptKey(route: try route(host: alias))
                    == canonicalIPv4Key
            )
        }
    }

    @Test func cleanupDebtCapSurfacesRestartRequiredError() async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(
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

    @Test func globalCleanupBudgetIncludesEveryRouteAndUntrackedDial()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        var leases: [MobileRPCConnectAttemptLease] = []
        for index in 0..<15 {
            let key = debugConnectAttemptKey(port: 58_900 + index)
            guard case let .granted(lease) =
                    await registry.beginConnect(key: key) else {
                Issue.record("Expected global admission \(index)")
                return
            }
            leases.append(lease)
        }
        guard case let .granted(untrackedLease) =
                await registry.beginConnect(key: nil) else {
            Issue.record("Expected untracked global admission")
            return
        }
        leases.append(untrackedLease)
        let overflowKey = debugConnectAttemptKey(port: 58_999)
        #expect(await registry.beginConnect(key: overflowKey) == .busy)

        let cleanupGates = (0..<leases.count).map { _ in
            PhysicalCleanupGate()
        }
        for (lease, gate) in zip(leases, cleanupGates) {
            await registry.handOffPhysicalCleanup(lease: lease) {
                await gate.wait()
            }
        }
        #expect(
            await registry.beginConnect(key: overflowKey)
                == .cleanupBlocked
        )

        await cleanupGates[0].release()
        var reopenedLease: MobileRPCConnectAttemptLease?
        for _ in 0..<20 {
            if case let .granted(lease) =
                await registry.beginConnect(key: overflowKey) {
                reopenedLease = lease
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await registry.finishConnect(lease: reopenedLease)
        for gate in cleanupGates.dropFirst() {
            await gate.release()
        }
    }

    @Test func installedTransportCloseRetainsPhysicalCleanupAdmission()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(port: 58_987)
        let transport = ReleasableConnectTransport(holdsClose: true)
        await transport.releaseConnect()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: { transport }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "installed-close-admission"
        )

        _ = try await session.send(
            payload: request,
            requestID: "installed-close-admission",
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds
                + 60_000_000_000
        )
        #expect(await registry.beginConnect(key: key) == .busy)

        await session.tearDown(error: .connectionClosed)
        await transport.waitUntilCloseStarted()
        guard case let .granted(recoveryLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected one recovery beside installed close")
            await transport.releaseClose()
            return
        }
        let secondCleanup = PhysicalCleanupGate()
        await registry.handOffPhysicalCleanup(lease: recoveryLease) {
            await secondCleanup.wait()
        }
        #expect(await registry.beginConnect(key: key) == .cleanupBlocked)

        await transport.releaseClose()
        await secondCleanup.release()
        await session.waitForTransportDrain()
    }

    @Test func recoveredInstalledClosesOwnIndependentCleanupLifetimes()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 58_986
        )
        let key = MobileRPCConnectAttemptKey(route: route)
        let first = ReleasableConnectTransport(holdsClose: true)
        let second = ReleasableConnectTransport(holdsClose: true)
        await first.releaseConnect()
        await second.releaseConnect()
        let factory = SequencedTransportFactory([first, second])
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: {
                try factory.makeTransport(for: route)
            }
        )
        func send(_ id: String) async throws {
            _ = try await session.send(
                payload: MobileCoreRPCClient.requestData(
                    method: "mobile.host.status",
                    id: id
                ),
                requestID: id,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
        }

        try await send("first-installed-close")
        await session.tearDown(error: .connectionClosed)
        await first.waitUntilCloseStarted()
        try await send("second-installed-close")
        await session.tearDown(error: .connectionClosed)
        await second.waitUntilCloseStarted()

        #expect(await registry.beginConnect(key: key) == .cleanupBlocked)
        await first.releaseClose()
        await second.releaseClose()
        await session.waitForTransportDrain()
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
    }

    @Test func rejectedFactoryTransportDisposalRetainsCleanupAdmission()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(port: 58_985)
        let lifecycleGate = MobileRPCClientLifecycleGate()
        let transport = ReleasableConnectTransport(holdsClose: true)
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            makeTransport: {
                try lifecycleGate.makeTransport {
                    lifecycleGate.retire()
                    return transport
                }
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "factory-disposal-admission"
        )

        do {
            _ = try await session.send(
                payload: request,
                requestID: "factory-disposal-admission",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
            Issue.record("Expected retired factory admission to fail")
        } catch MobileShellConnectionError.connectionClosed {
        } catch {
            Issue.record("Expected connectionClosed, got \(error)")
        }
        await transport.waitUntilCloseStarted()
        guard case let .granted(recoveryLease) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected one recovery beside factory disposal")
            await transport.releaseClose()
            return
        }
        let secondCleanup = PhysicalCleanupGate()
        await registry.handOffPhysicalCleanup(lease: recoveryLease) {
            await secondCleanup.wait()
        }
        #expect(await registry.beginConnect(key: key) == .cleanupBlocked)

        await transport.releaseClose()
        await secondCleanup.release()
        await lifecycleGate.waitForRetiredTransportDisposals()
    }

    @Test func cancellationHandlerCloseRetainsCleanupAdmission()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(port: 58_984)
        let transport =
            CancellationThrowingConnectHangingCloseTransport()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            abandonedConnectCleanupTimeoutNanoseconds: 1_000_000,
            lateAbandonedConnectCloseTimeoutNanoseconds: 1_000_000,
            makeTransport: { transport }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "cancellation-close-admission"
        )
        let send = Task {
            try await session.send(
                payload: request,
                requestID: "cancellation-close-admission",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
        }
        await transport.waitUntilConnectStarted()
        send.cancel()
        _ = await send.result
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
        guard let recoveryLease else {
            Issue.record("Expected one recovery beside cancellation close")
            await transport.releaseClose()
            return
        }
        let secondCleanup = PhysicalCleanupGate()
        await registry.handOffPhysicalCleanup(lease: recoveryLease) {
            await secondCleanup.wait()
        }
        #expect(await registry.beginConnect(key: key) == .cleanupBlocked)

        await transport.releaseClose()
        await secondCleanup.release()
        await session.waitForTransportDrain()
    }

    @Test func concurrentTeardownJoinsCleanupRegistration()
        async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = debugConnectAttemptKey(port: 58_983)
        let transport =
            CancellationThrowingConnectHangingCloseTransport()
        let registrationGate = TeardownRegistrationGate()
        let session = MobileCoreRPCSession(
            connectAttemptKey: key,
            connectAttemptRegistry: registry,
            abandonedConnectCleanupTimeoutNanoseconds: 1_000_000,
            lateAbandonedConnectCloseTimeoutNanoseconds: 1_000_000,
            makeTransport: { transport },
            tearDownRegistrationHook: {
                await registrationGate.wait()
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "joined-teardown"
        )
        let send = Task {
            try await session.send(
                payload: request,
                requestID: "joined-teardown",
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                    + 60_000_000_000
            )
        }
        await transport.waitUntilConnectStarted()
        let first = Task {
            await session.tearDown(error: .connectionClosed)
        }
        await registrationGate.waitUntilEntered()
        let secondCompletion = TeardownCompletion()
        let second = Task {
            await session.tearDown(error: .connectionClosed)
            await secondCompletion.finish()
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(!(await secondCompletion.isFinished))

        await registrationGate.release()
        await first.value
        await second.value
        #expect(await secondCompletion.isFinished)
        let recoveryAdmission = await registry.beginConnect(key: key)
        switch recoveryAdmission {
        case .granted(let recoveryLease):
            await registry.finishConnect(lease: recoveryLease)
        case .busy, .cleanupBlocked:
            Issue.record(
                "Teardown returned before abandoned reconnect cleanup registration"
            )
        }

        await transport.waitUntilCloseStarted()
        await transport.releaseClose()
        await session.waitForTransportDrain()
        send.cancel()
        _ = await send.result
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
    port: Int
) -> MobileRPCConnectAttemptKey {
    let route = try! CmxAttachRoute(
        id: "test",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: port)
    )
    return MobileRPCConnectAttemptKey(
        route: route
    )
}
