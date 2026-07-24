import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite(.serialized) struct MobileCoreRPCConnectWaiterTests {
    @Test func successfulConnectNeverPublishesHalfInstalledWriterState() async throws {
        let arrivals = ConnectedCandidateBarrier(expectedCount: 2)
        let transport = ReleasableConnectTransport()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await arrivals.arrive()
            }
        )
        let first = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "first-install-waiter"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "second-install-waiter"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000

        let firstTask = Task {
            try await session.send(
                payload: first,
                requestID: "first-install-waiter",
                deadlineUptimeNanoseconds: deadline
            )
        }
        #expect(await transport.waitUntilConnectStarted())
        let secondTask = Task {
            try await session.send(
                payload: second,
                requestID: "second-install-waiter",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await transport.releaseConnect()

        do {
            _ = try await secondTask.value
            _ = try await firstTask.value
        } catch {
            firstTask.cancel()
            _ = try? await firstTask.value
            throw error
        }

        #expect(!(await transport.closed()))
        #expect(try await Set(transport.sentRequests().compactMap(\.id)) == [
            "first-install-waiter",
            "second-install-waiter",
        ])
        await session.tearDown(error: .connectionClosed)
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
        for _ in 0..<100 {
            await Task.yield()
        }

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

    @Test func cancelledPostConnectWaiterDoesNotCloseTransportForSurvivor() async throws {
        let cancellation = ConnectCancellationBox()
        let arrivals = ConnectedCandidateBarrier(expectedCount: 2)
        let transport = ReleasableConnectTransport()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await arrivals.arrive()
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
        let survivingTask = Task {
            try await session.send(
                payload: surviving,
                requestID: "surviving-after-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await cancellation.set(cancelledTask)
        #expect(await transport.waitUntilConnectStarted())

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
        await session.tearDown(error: .connectionClosed)
    }

    @Test func cancelledPostConnectOnlyWaiterClosesTransport() async throws {
        let cancellation = ConnectCancellationBox()
        let transport = ReleasableConnectTransport()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await cancellation.cancelWhenSet()
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "cancelled-only-after-connect"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000

        let cancelledTask = Task {
            try await session.send(
                payload: request,
                requestID: "cancelled-only-after-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await cancellation.set(cancelledTask)
        #expect(await transport.waitUntilConnectStarted())
        await transport.releaseConnect()

        do {
            _ = try await cancelledTask.value
            Issue.record("Expected cancelled waiter to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(await waitUntilClosed(transport))
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func cancelledPostConnectOnlyWaiterDoesNotWaitForHangingClose() async throws {
        let cancellation = ConnectCancellationBox()
        let transport = HangingCloseTransport()
        let session = MobileCoreRPCSession(
            lateAbandonedConnectCloseTimeoutNanoseconds: 1_000_000,
            makeTransport: { transport },
            didReceiveConnectedCandidate: { _ in
                await cancellation.cancelWhenSet()
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "cancelled-hanging-close"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000

        let cancelledTask = Task {
            try await session.send(
                payload: request,
                requestID: "cancelled-hanging-close",
                deadlineUptimeNanoseconds: deadline
            )
        }
        await cancellation.set(cancelledTask)

        do {
            _ = try await cancelledTask.value
            Issue.record("Expected cancelled waiter to throw")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        await transport.waitUntilCloseStarted()
        await transport.releaseClose()
    }

    private func waitUntilClosed(_ transport: ReleasableConnectTransport) async -> Bool {
        for _ in 0..<100 {
            if await transport.closed() {
                return true
            }
            await Task.yield()
        }
        return await transport.closed()
    }
}

private actor ConnectedCandidateBarrier {
    private let expectedCount: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func arrive() async {
        arrivalCount += 1
        guard arrivalCount < expectedCount else {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
