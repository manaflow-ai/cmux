import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileRPCTransportConnectEventTests {
    @Test func factoryFailureUsesOnePositiveCorrelationIDAndTypedFailure() async throws {
        let (events, continuation) = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let session = MobileCoreRPCSession(
            makeTransport: { () throws -> any CmxByteTransport in
                throw MobileShellConnectionError.insecureManualRoute
            },
            diagnosticTransport: .iroh,
            transportConnectObserver: { event in
                _ = continuation.yield(event)
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "factory-failure"
        )

        do {
            _ = try await session.send(
                payload: request,
                requestID: "factory-failure",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
            Issue.record("Expected transport construction to fail")
        } catch MobileShellConnectionError.insecureManualRoute {
        } catch {
            Issue.record("Expected insecureManualRoute, got \(error)")
        }

        continuation.finish()
        let recorded = await collect(events)
        #expect(recorded.count == 2)
        guard recorded.count == 2 else { return }
        guard case let .attempt(attemptID, transport) = recorded[0] else {
            Issue.record("Expected attempt event first")
            return
        }
        #expect(attemptID > 0)
        #expect(transport == .iroh)
        guard case let .failed(failedID, failedTransport, failure, _) = recorded[1] else {
            Issue.record("Expected failed event second")
            return
        }
        #expect(failedID == attemptID)
        #expect(failedTransport == .iroh)
        #expect(failure == .unsupportedRoute)
    }

    @Test func cancelledHungDialEmitsCancelledOutcomeWithElapsedTime() async throws {
        let transport = FirstConnectHangsThenSucceedsTransport()
        let (events, continuation) = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            diagnosticTransport: .iroh,
            transportConnectObserver: { event in
                _ = continuation.yield(event)
            }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "hung-dial"
        )
        let pending = Task {
            try await session.send(
                payload: request,
                requestID: "hung-dial",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    + 60 * 1_000_000_000
            )
        }

        while await transport.connectCount() < 1 {
            await Task.yield()
        }
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Expected the hung dial to throw CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await transport.waitUntilFirstAttemptClosed())

        let recorded = await collect(events, atLeast: 2)
        continuation.finish()
        #expect(recorded.count == 2)
        guard recorded.count == 2 else {
            await session.tearDown(error: .connectionClosed)
            return
        }
        guard case let .attempt(attemptID, attemptTransport) = recorded[0] else {
            Issue.record("Expected attempt event first, got \(recorded[0])")
            await session.tearDown(error: .connectionClosed)
            return
        }
        guard case let .failed(
            failedID,
            failedTransport,
            failure,
            elapsedMilliseconds
        ) = recorded[1] else {
            Issue.record("Expected a cancelled outcome event, got \(recorded[1])")
            await session.tearDown(error: .connectionClosed)
            return
        }
        #expect(failedID == attemptID)
        #expect(attemptTransport == .iroh)
        #expect(failedTransport == .iroh)
        #expect(failure == .cancelled)
        #expect(elapsedMilliseconds >= 0)
        #expect(Self.outcomeCountsPerAttempt(recorded) == [attemptID: 1])
        await session.tearDown(error: .connectionClosed)
    }

    @Test func callerCancellationReportsCancelledOutcomeAndRetryConnects() async throws {
        let transport = FirstConnectClosedErrorThenSucceedsTransport()
        let (events, continuation) = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            diagnosticTransport: .debugLoopback,
            transportConnectObserver: { event in
                _ = continuation.yield(event)
            }
        )
        let first = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "cancelled-closed-connect"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "retry-after-closed-connect"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000
        let firstTask = Task {
            try await session.send(
                payload: first,
                requestID: "cancelled-closed-connect",
                deadlineUptimeNanoseconds: deadline
            )
        }

        await transport.waitUntilFirstConnectStarted()
        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("Expected first request to throw CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        await transport.waitUntilFirstConnectFinished()

        let data = try await session.send(
            payload: second,
            requestID: "retry-after-closed-connect",
            deadlineUptimeNanoseconds: deadline
        )
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")
        #expect(await transport.connectCount() == 2)
        #expect(try await transport.sentRequests().map(\.id) == ["retry-after-closed-connect"])

        let recorded = await collect(events, atLeast: 4)
        continuation.finish()
        #expect(recorded.count == 4)
        guard recorded.count == 4 else {
            await session.tearDown(error: .connectionClosed)
            return
        }
        guard case let .attempt(firstAttemptID, firstTransport) = recorded[0] else {
            Issue.record("Expected an attempt event first, got \(recorded[0])")
            await session.tearDown(error: .connectionClosed)
            return
        }
        // The transport surfaces its close error instead of `CancellationError`
        // after the cancellation handler closes it. That is an abandoned dial,
        // not a real failure, so it is classified `cancelled`.
        guard let cancelled = recorded.dropFirst().first(where: {
            if case .failed = $0 { return true }
            return false
        }), case let .failed(cancelledID, _, failure, _) = cancelled else {
            Issue.record("Expected a cancelled outcome for the abandoned dial")
            await session.tearDown(error: .connectionClosed)
            return
        }
        #expect(cancelledID == firstAttemptID)
        #expect(failure == .cancelled)
        guard let secondAttempt = recorded.first(where: {
            if case let .attempt(id, _) = $0 { return id != firstAttemptID }
            return false
        }), case let .attempt(secondAttemptID, secondTransport) = secondAttempt,
            let connected = recorded.first(where: {
                if case .connected = $0 { return true }
                return false
            }), case let .connected(connectedID, connectedTransport, _) = connected else {
            Issue.record("Expected a second attempt that connected")
            await session.tearDown(error: .connectionClosed)
            return
        }
        #expect(firstAttemptID > 0)
        #expect(secondAttemptID > 0)
        #expect(firstTransport == .debugLoopback)
        #expect(secondTransport == .debugLoopback)
        #expect(connectedID == secondAttemptID)
        #expect(connectedTransport == .debugLoopback)
        // Every started dial has exactly one outcome event.
        #expect(Self.outcomeCountsPerAttempt(recorded) == [
            firstAttemptID: 1,
            secondAttemptID: 1,
        ])
        await session.tearDown(error: .connectionClosed)
    }

    @Test func mobileShellErrorsProvideStablePrivacySafeClassifications() {
        #expect(MobileShellConnectionError.invalidResponse.diagnosticFailureKind == .protocolViolation)
        #expect(MobileShellConnectionError.connectionClosed.diagnosticFailureKind == .connectionClosed)
        #expect(MobileShellConnectionError.requestTimedOut.diagnosticFailureKind == .timedOut)
        #expect(MobileShellConnectionError.transportWriteTimedOut.diagnosticFailureKind == .timedOut)
        #expect(MobileShellConnectionError.connectAttemptGated.diagnosticFailureKind == .routeGated)
        #expect(
            MobileShellConnectionError.routeCleanupBlocked.diagnosticFailureKind
                == .admissionDenied
        )
        #expect(MobileShellConnectionError.insecureManualRoute.diagnosticFailureKind == .unsupportedRoute)
        #expect(MobileShellConnectionError.attachTicketExpired.diagnosticFailureKind == .credentialUnavailable)
        #expect(
            MobileShellConnectionError.authorizationFailed("sensitive").diagnosticFailureKind
                == .authorizationFailed
        )
        #expect(
            MobileShellConnectionError.accountMismatch("sensitive").diagnosticFailureKind
                == .accountMismatch
        )
        #expect(
            MobileShellConnectionError.rpcError("private-code", "sensitive").diagnosticFailureKind
                == .protocolViolation
        )
    }

    private func collect(
        _ stream: AsyncStream<MobileRPCTransportConnectEvent>
    ) async -> [MobileRPCTransportConnectEvent] {
        var events: [MobileRPCTransportConnectEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// Drain `count` events, or everything that arrived within a bounded wait.
    /// Outcome events are emitted by the detached dial task, so a caller that
    /// already threw may observe them slightly later.
    private func collect(
        _ stream: AsyncStream<MobileRPCTransportConnectEvent>,
        atLeast count: Int
    ) async -> [MobileRPCTransportConnectEvent] {
        let collected = Collected()
        return await withTaskGroup(
            of: Void.self,
            returning: [MobileRPCTransportConnectEvent].self
        ) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while await collected.count() < count,
                      let event = await iterator.next() {
                    await collected.append(event)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
            await group.next()
            group.cancelAll()
            return await collected.events()
        }
    }

    private actor Collected {
        private var stored: [MobileRPCTransportConnectEvent] = []

        func append(_ event: MobileRPCTransportConnectEvent) {
            stored.append(event)
        }

        func count() -> Int { stored.count }
        func events() -> [MobileRPCTransportConnectEvent] { stored }
    }

    /// Number of terminal outcome events per attempt ID. Exactly one outcome
    /// per started dial is the invariant a diagnostic export depends on.
    private static func outcomeCountsPerAttempt(
        _ events: [MobileRPCTransportConnectEvent]
    ) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for event in events {
            switch event {
            case .attempt:
                continue
            case let .connected(attemptID, _, _),
                 let .failed(attemptID, _, _, _):
                counts[attemptID, default: 0] += 1
            }
        }
        return counts
    }
}
