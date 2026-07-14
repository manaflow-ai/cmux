import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCStalledWriteRecoveryTests {
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

        // A cancelled send may unwind after its replacement transport is live.
        // Its stale writer must not tear down the newer connection.
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
        let stalledRequest = try inputRequest(id: "cancelled-stalled-write", text: "a")
        let cancelledTask = Task {
            try await client.sendRequest(
                stalledRequest,
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            Issue.record("Expected the stalled request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let retry = try inputRequest(id: "second-after-cancel", text: "b")
        _ = try await client.sendRequest(retry, timeoutNanoseconds: 500_000_000)

        #expect(factory.createdTransportCount() == 2)
        #expect(await stalled.closed())
        await stalled.failStalledSend()
        await client.disconnect()
    }

    @Test func recoveryResetDoesNotWaitForHangingTransportClose() async throws {
        let stalled = StalledWriteTransport(hangsOnClose: true)
        let recovery = ResponseTimeoutSurvivalTransport()
        let factory = StalledWriteRecoveryTransportFactory(
            stalled: stalled,
            recovery: recovery
        )
        let client = try makeClient(factory: factory)
        let firstRequest = try inputRequest(id: "first-before-reset", text: "a")
        let firstTask = Task {
            try await client.sendRequest(
                firstRequest,
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        let resetFinished = AsyncFlag()
        let resetTask = Task {
            await client.resetConnectionForRecovery()
            await resetFinished.set()
        }
        await stalled.waitUntilCloseStarted()
        for _ in 0..<100 where !(await resetFinished.isSet()) {
            await Task.yield()
        }
        #expect(await resetFinished.isSet())

        let retry = try inputRequest(id: "second-after-hanging-close", text: "b")
        _ = try await client.sendRequest(retry, timeoutNanoseconds: 500_000_000)
        #expect(factory.createdTransportCount() == 2)

        await stalled.releaseClose()
        await stalled.failStalledSend()
        await resetTask.value
        _ = try? await firstTask.value
        await client.disconnect()
    }

    @Test func transportCloseCleanupRetainsOnlyNewestPendingTransport() async throws {
        let first = StalledWriteTransport(hangsOnClose: true)
        let superseded = StalledWriteTransport(hangsOnClose: true)
        let newest = StalledWriteTransport(hangsOnClose: true)
        let factory = SequencedTransportFactory([first, superseded, newest])
        let client = try makeClient(factory: factory)

        let firstTask = Task {
            try await client.sendRequest(
                inputRequest(id: "close-first", text: "a"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }
        await first.waitUntilSendStarted()
        await client.resetConnectionForRecovery()
        await first.waitUntilCloseStarted()

        let supersededTask = Task {
            try await client.sendRequest(
                inputRequest(id: "close-superseded", text: "b"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }
        await superseded.waitUntilSendStarted()
        await client.resetConnectionForRecovery()

        let newestTask = Task {
            try await client.sendRequest(
                inputRequest(id: "close-newest", text: "c"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }
        await newest.waitUntilSendStarted()
        await client.resetConnectionForRecovery()

        #expect(await first.closed())
        #expect(!(await superseded.closed()))
        #expect(!(await newest.closed()))
        #expect(factory.createdTransportCount() == 3)

        await first.releaseClose()
        await newest.waitUntilCloseStarted()
        #expect(!(await superseded.closed()))

        await newest.releaseClose()
        await superseded.releaseClose()
        await superseded.close()
        await first.failStalledSend()
        await superseded.failStalledSend()
        await newest.failStalledSend()
        _ = try? await firstTask.value
        _ = try? await supersededTask.value
        _ = try? await newestTask.value
        await client.disconnect()
    }

    private func makeClient(
        factory: any CmxByteTransportFactory
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
