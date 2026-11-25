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

    @Test func cancelledInFlightWriteThatCompletesPreservesTransport() async throws {
        let transport = ControllableResponseTransport(
            closeEndsReceive: true,
            blocksFirstSend: true,
            automaticallyRespondingRequestIDs: ["second-after-cancel"]
        )
        let factory = SequencedTransportFactory([
            transport,
            ResponseTimeoutSurvivalTransport(),
        ])
        let client = try makeClient(factory: factory)
        let task = Task {
            try await client.sendRequest(
                try inputRequest(id: "cancelled-brief-write", text: "a"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }

        await transport.waitUntilSent(count: 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        await transport.releaseFirstSend()
        let data = try await client.sendRequest(
            try inputRequest(id: "second-after-cancel", text: "b"),
            timeoutNanoseconds: 500_000_000
        )
        let response = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(response["status"] == "ok")
        #expect(factory.createdTransportCount() == 1)
        #expect(!(await transport.closed()))
        await client.disconnect()
    }

    @Test func cancelledInFlightWriteIsNotRecycledWithoutLaterDemand() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 10_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let task = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-idle-write", text: "a"),
                requestID: "cancelled-idle-write",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        task.cancel()
        _ = try? await task.value

        #expect(factory.createdTransportCount() == 1)
        #expect(!(await stalled.closed()))

        await session.tearDown(error: .connectionClosed)
        await stalled.failStalledSend()
    }

    @Test func queuedRequestBehindCancelledStalledWriteRecyclesWithinGrace() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 50_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let headTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-stalled-head", text: "a"),
                requestID: "cancelled-stalled-head",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        let queuedTask = Task {
            try await session.send(
                payload: try inputRequest(id: "queued-behind-cancel", text: "b"),
                requestID: "queued-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 2_000_000_000
            )
        }
        // The queued request must be registered behind the stalled head write
        // BEFORE the head is cancelled: it has already passed the send()
        // recovery gate, so recycling cannot rely on a later send() call.
        var queuedReachedGate = false
        for _ in 0..<1000 {
            if await session.queuedRequestIDs.contains("queued-behind-cancel") {
                queuedReachedGate = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(queuedReachedGate)

        let startedAt = ContinuousClock.now
        headTask.cancel()
        do {
            _ = try await headTask.value
            Issue.record("Expected the stalled head request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        do {
            _ = try await queuedTask.value
            Issue.record("Expected the queued request to fail on recycle")
        } catch MobileShellConnectionError.connectionClosed {
        } catch {
            Issue.record("Expected connectionClosed, got \(error)")
        }
        let elapsed = startedAt.duration(to: .now)

        // The queued request must fail fast via the grace recycle, not hang
        // until its own deadline behind the cancellation-ignoring send.
        #expect(elapsed < .seconds(1))
        // Bounded poll instead of waitUntilCloseStarted(): if recovery never
        // recycles, the transport is never closed and an unbounded wait would
        // hang the suite instead of failing it.
        var stalledClosed = false
        for _ in 0..<1000 {
            if await stalled.closed() {
                stalledClosed = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(stalledClosed)

        await stalled.failStalledSend()
        await session.tearDown(error: .connectionClosed)
    }

    @Test func queuedRequestTimeoutBehindCancelledWriteRecyclesPromptly() async throws {
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
        // Grace far beyond the queued request's deadline: recovery must come
        // from the queued request's own timeout, not the grace watchdog.
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 60 * 1_000_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let headTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-head-long-grace", text: "a"),
                requestID: "cancelled-head-long-grace",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        let queuedTask = Task {
            try await session.send(
                payload: try inputRequest(id: "short-deadline-behind-cancel", text: "b"),
                requestID: "short-deadline-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 150_000_000
            )
        }
        var queuedReachedGate = false
        for _ in 0..<1000 {
            if await session.queuedRequestIDs.contains("short-deadline-behind-cancel") {
                queuedReachedGate = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(queuedReachedGate)

        headTask.cancel()
        do {
            _ = try await headTask.value
            Issue.record("Expected the stalled head request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        // The queued request dies at its own deadline while head-of-line
        // blocked behind the cancelled write. That death is unserved demand:
        // it must condemn the wedged transport immediately rather than be
        // erased from the demand signal like an explicit cancellation.
        do {
            _ = try await queuedTask.value
            Issue.record("Expected the queued request to time out")
        } catch MobileShellConnectionError.transportWriteTimedOut {
        } catch {
            Issue.record("Expected transportWriteTimedOut, got \(error)")
        }
        var stalledClosed = false
        for _ in 0..<1000 {
            if await stalled.closed() {
                stalledClosed = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(stalledClosed)

        await stalled.failStalledSend()
        await session.tearDown(error: .connectionClosed)
    }

    @Test func recycledWriteResolutionDrainsCoalescedWaiters() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 500_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-before-waiter-drain", text: "a"),
                requestID: "cancelled-before-waiter-drain",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        firstTask.cancel()
        _ = try? await firstTask.value

        do {
            _ = try await session.send(
                payload: try inputRequest(id: "drained-behind-cancel", text: "b"),
                requestID: "drained-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 30_000_000
            )
            Issue.record("Expected the gated request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        // The recycle that failed the gated request must also drain its
        // coalesced resolution waiter instead of leaving it parked until the
        // stalled send eventually returns.
        #expect(await session.writeResolutionWaiterCount == 0)

        await stalled.failStalledSend()
        await session.tearDown(error: .connectionClosed)
    }

    @Test func cancelledWriteResolutionHonorsNextRequestDeadline() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 500_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-before-deadline", text: "a"),
                requestID: "cancelled-before-deadline",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        firstTask.cancel()
        _ = try? await firstTask.value

        let startedAt = ContinuousClock.now
        do {
            _ = try await session.send(
                payload: try inputRequest(id: "deadline-behind-cancel", text: "b"),
                requestID: "deadline-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 30_000_000
            )
            Issue.record("Expected the next request to honor its deadline")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        let elapsed = startedAt.duration(to: .now)

        #expect(elapsed < .milliseconds(200))
        await stalled.waitUntilCloseStarted()
        #expect(await stalled.closed())

        await stalled.failStalledSend()
        await session.tearDown(error: .connectionClosed)
    }

    @Test func expiredNextRequestRecyclesCancelledStalledWrite() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 500_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-before-expiry", text: "a"),
                requestID: "cancelled-before-expiry",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        firstTask.cancel()
        _ = try? await firstTask.value

        do {
            _ = try await session.send(
                payload: try inputRequest(id: "expired-behind-cancel", text: "b"),
                requestID: "expired-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            Issue.record("Expected the expired request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        await stalled.waitUntilCloseStarted()
        #expect(await stalled.closed())

        await stalled.failStalledSend()
        await session.tearDown(error: .connectionClosed)
    }

    @Test func cancelledWriteResolutionHonorsNextRequestCancellation() async throws {
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
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 500_000_000,
            makeTransport: { try factory.makeTransport(for: route) }
        )
        let firstTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancelled-before-cancel", text: "a"),
                requestID: "cancelled-before-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        await stalled.waitUntilSendStarted()
        firstTask.cancel()
        _ = try? await firstTask.value

        let startedAt = ContinuousClock.now
        let nextTask = Task {
            try await session.send(
                payload: try inputRequest(id: "cancel-behind-cancel", text: "b"),
                requestID: "cancel-behind-cancel",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        nextTask.cancel()
        do {
            _ = try await nextTask.value
            Issue.record("Expected the waiting request to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        let elapsed = startedAt.duration(to: .now)

        #expect(elapsed < .milliseconds(200))
        #expect(!(await stalled.closed()))

        // The cancelled gated request must unregister its coalesced waiter;
        // the write is intentionally still unresolved here, so a leaked
        // continuation would sit in the waiter map until teardown.
        var waitersDrained = false
        for _ in 0..<1000 {
            if await session.writeResolutionWaiterCount == 0 {
                waitersDrained = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(waitersDrained)

        await session.tearDown(error: .connectionClosed)
        await stalled.failStalledSend()
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
        for _ in 0..<200 where !(await teardownFinished.isSet()) {
            try await Task.sleep(nanoseconds: 1_000_000)
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
            connectAttemptKey: MobileRPCConnectAttemptKey(route: route),
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
        } catch MobileShellConnectionError.routeCleanupBlocked {
        } catch {
            Issue.record("Expected routeCleanupBlocked, got \(error)")
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
