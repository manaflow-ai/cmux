import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite(.serialized) struct MobileCoreRPCStalledWriteRecoveryTests {
    @Test func timedOutInFlightWriteRecyclesTransportForNextRequest() async throws {
        let stalled = StalledWriteTransport()
        let recovery = ResponseTimeoutSurvivalTransport()
        let factory = StalledWriteRecoveryTransportFactory(
            stalled: stalled,
            recovery: recovery
        )
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59135
        )
        let runtime = TestMobileSyncRuntime(
            transportFactory: factory,
            rpcRequestTimeoutNanoseconds: 50_000_000
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

        let stalledRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "a",
            ],
            id: "stalled-write"
        )
        do {
            _ = try await client.sendRequest(stalledRequest)
            Issue.record("Expected the stalled write to time out")
        } catch MobileShellConnectionError.transportWriteTimedOut {
        } catch {
            Issue.record("Expected transportWriteTimedOut, got \(error)")
        }

        let retryRequest = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "b",
            ],
            id: "second-after-timeout"
        )
        do {
            let data = try await client.sendRequest(
                retryRequest,
                timeoutNanoseconds: 500_000_000
            )
            let response = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(response["status"] == "ok")
        } catch {
            Issue.record("The request after a stalled write should reconnect, got \(error)")
        }

        // The abandoned send may unwind after its replacement is live. Its
        // connection generation must not tear down the replacement.
        await stalled.failStalledSend()
        let requestAfterLateFailure = try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "c",
            ],
            id: "third-after-late-failure"
        )
        _ = try await client.sendRequest(
            requestAfterLateFailure,
            timeoutNanoseconds: 500_000_000
        )

        #expect(factory.createdTransportCount() == 2)
        #expect(await stalled.closed())
        await client.disconnect()
    }

    @Test func cancelledInFlightWriteRecyclesTransportForNextRequest() async throws {
        let stalled = StalledWriteTransport()
        let recovery = ResponseTimeoutSurvivalTransport()
        let factory = StalledWriteRecoveryTransportFactory(
            stalled: stalled,
            recovery: recovery
        )
        let client = try makeClient(factory: factory)
        let task = Task {
            try await client.sendRequest(
                try inputRequest(id: "cancelled-stalled-write", text: "a"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the stalled request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        _ = try await client.sendRequest(
            try inputRequest(id: "second-after-cancel", text: "b"),
            timeoutNanoseconds: 500_000_000
        )

        #expect(factory.createdTransportCount() == 2)
        #expect(await stalled.closed())
        await stalled.failStalledSend()
        await client.disconnect()
    }

    @Test func teardownDoesNotWaitForHangingTransportClose() async throws {
        let stalled = StalledWriteTransport(hangsOnClose: true)
        let recovery = ResponseTimeoutSurvivalTransport()
        let factory = StalledWriteRecoveryTransportFactory(
            stalled: stalled,
            recovery: recovery
        )
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59135
        )
        let session = MobileCoreRPCSession(
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "first-before-reset", text: "a"),
                requestID: "first-before-reset",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        let teardownFinished = AsyncFlag()
        let teardownTask = Task {
            await session.tearDown(error: .connectionClosed)
            await teardownFinished.set()
        }
        await stalled.waitUntilCloseStarted()
        for _ in 0..<100 where !(await teardownFinished.isSet()) {
            await Task.yield()
        }
        #expect(await teardownFinished.isSet())

        let retryPayload = try inputRequest(id: "second-after-hanging-close", text: "b")
        _ = try await session.send(
            payload: retryPayload,
            requestID: "second-after-hanging-close",
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                + 500_000_000
        )
        #expect(factory.createdTransportCount() == 2)

        await stalled.releaseClose()
        await stalled.failStalledSend()
        await teardownTask.value
        _ = try? await firstTask.value
        await session.tearDown(error: .connectionClosed)
    }

    @Test func hangingCloseBackpressuresWithoutDroppingCleanup() async throws {
        let first = StalledWriteTransport(hangsOnClose: true)
        let second = StalledWriteTransport(hangsOnClose: true)
        let third = StalledWriteTransport(hangsOnClose: true)
        let factory = SequencedTransportFactory([first, second, third])
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59137
        )
        let session = MobileCoreRPCSession(
            makeTransport: { try factory.makeTransport(for: route) }
        )

        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "close-first", text: "a"),
                requestID: "close-first",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }
        await first.waitUntilSendStarted()
        await session.tearDown(error: .connectionClosed)
        await first.waitUntilCloseStarted()

        let secondTask = Task {
            try await session.send(
                payload: try inputRequest(id: "close-second", text: "b"),
                requestID: "close-second",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }
        await second.waitUntilSendStarted()
        await session.tearDown(error: .connectionClosed)

        do {
            _ = try await session.send(
                payload: try inputRequest(id: "blocked-close", text: "c"),
                requestID: "blocked-close",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 500_000_000
            )
            Issue.record("Expected connection creation to wait for close capacity")
        } catch MobileShellConnectionError.connectionClosed {
        } catch {
            Issue.record("Expected connectionClosed, got \(error)")
        }
        #expect(factory.createdTransportCount() == 2)

        await first.releaseClose()
        await second.waitUntilCloseStarted()
        let thirdTask = Task {
            try await session.send(
                payload: try inputRequest(id: "close-third", text: "c"),
                requestID: "close-third",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }
        await third.waitUntilSendStarted()
        #expect(factory.createdTransportCount() == 3)
        await session.tearDown(error: .connectionClosed)

        await second.releaseClose()
        await third.waitUntilCloseStarted()
        await third.releaseClose()
        await first.failStalledSend()
        await second.failStalledSend()
        await third.failStalledSend()
        _ = try? await firstTask.value
        _ = try? await secondTask.value
        _ = try? await thirdTask.value
    }

    private func makeClient(
        factory: StalledWriteRecoveryTransportFactory
    ) throws -> MobileCoreRPCClient {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59135
        )
        let runtime = TestMobileSyncRuntime(
            transportFactory: factory,
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
        return MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
    }

    private func inputRequest(id: String, text: String) throws -> Data {
        try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": text,
            ],
            id: id
        )
    }
}
