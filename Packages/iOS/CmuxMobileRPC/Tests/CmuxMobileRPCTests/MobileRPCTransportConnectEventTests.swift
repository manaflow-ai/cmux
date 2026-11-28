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

    @Test func abandonedDialEmitsCancelledOutcomeAndRetryConnects() async throws {
        let transport = FirstConnectClosedErrorThenSucceedsTransport()
        let (events, continuation) = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let cancellationSignal = MobileRPCConnectCancellationSignal()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            diagnosticTransport: .debugLoopback,
            transportConnectObserver: { event in
                _ = continuation.yield(event)
                Task { await cancellationSignal.record(event) }
            }
        )
        let first = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "abandoned-connect"
        )
        let second = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "retry-after-abandoned-connect"
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000
        let firstTask = Task {
            try await session.send(
                payload: first,
                requestID: "abandoned-connect",
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
        #expect(await cancellationSignal.waitUntilObserved())

        let data = try await session.send(
            payload: second,
            requestID: "retry-after-abandoned-connect",
            deadlineUptimeNanoseconds: deadline
        )
        let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(response["status"] == "ok")

        continuation.finish()
        let recorded = await collect(events)
        #expect(recorded.count == 5)
        guard recorded.count == 5 else {
            await session.tearDown(error: .connectionClosed)
            return
        }
        guard case let .attempt(firstAttemptID, _) = recorded[0],
              case let .cancelled(cancelledID, cancelledTransport, cancellationReason, _) = recorded[1],
              case let .failed(abandonedID, abandonedTransport, abandonedFailure, _) = recorded[2],
              case let .attempt(secondAttemptID, _) = recorded[3],
              case let .connected(connectedID, _, _, sessionID) = recorded[4] else {
            Issue.record("Expected attempt, cancelled(reason), failed(cancelled), attempt, connected")
            await session.tearDown(error: .connectionClosed)
            return
        }
        #expect(abandonedID == firstAttemptID)
        #expect(cancelledID == firstAttemptID)
        #expect(cancelledTransport == .debugLoopback)
        #expect(cancellationReason == .requestCancelled)
        #expect(abandonedTransport == .debugLoopback)
        #expect(abandonedFailure == .cancelled)
        #expect(connectedID == secondAttemptID)
        #expect(sessionID == nil)
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

    @Test func connectedDialCarriesAdmittedSessionLink() async throws {
        let transport = LinkedDiagnosticSessionTransport(sessionID: 91)
        let (events, continuation) = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let session = MobileCoreRPCSession(
            makeTransport: { transport },
            diagnosticTransport: .iroh,
            transportConnectObserver: { event in _ = continuation.yield(event) }
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            id: "linked-session"
        )
        _ = try await session.send(
            payload: request,
            requestID: "linked-session",
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                + 5 * 1_000_000_000
        )
        await session.tearDown(error: .connectionClosed)
        continuation.finish()
        let recorded = await collect(events)
        #expect(recorded.count == 2)
        guard case .attempt = recorded[0],
              case let .connected(_, _, _, sessionID) = recorded[1] else {
            Issue.record("Expected attempt followed by connected")
            return
        }
        #expect(sessionID == 91)
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
}

private actor LinkedDiagnosticSessionTransport:
    CmxByteTransportDiagnosticSessionIdentifying
{
    private let base: ControllableResponseTransport
    private let sessionID: Int

    init(sessionID: Int) {
        self.base = ControllableResponseTransport(
            closeEndsReceive: true,
            automaticallyRespondingRequestIDs: ["linked-session"]
        )
        self.sessionID = sessionID
    }

    func connect() async throws { try await base.connect() }
    func receive() async throws -> Data? { try await base.receive() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func close() async { await base.close() }
    func transportDiagnosticSessionID() async -> Int? { sessionID }
}

private actor MobileRPCConnectCancellationSignal {
    private var observed = false

    func record(_ event: MobileRPCTransportConnectEvent) {
        guard case let .failed(_, _, failure, _) = event,
              failure == .cancelled else {
            return
        }
        observed = true
    }

    func waitUntilObserved(
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !observed, clock.now < deadline {
            await Task.yield()
        }
        return observed
    }
}
