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

    @Test func callerCancellationSuppressesCloseInducedFailureAndRetryConnects() async throws {
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

        continuation.finish()
        let recorded = await collect(events)
        #expect(recorded.count == 3)
        guard recorded.count == 3 else {
            await session.tearDown(error: .connectionClosed)
            return
        }
        guard case let .attempt(firstAttemptID, firstTransport) = recorded[0],
              case let .attempt(secondAttemptID, secondTransport) = recorded[1],
              case let .connected(connectedID, connectedTransport, _) = recorded[2] else {
            Issue.record("Expected attempt, attempt, connected with no failure")
            await session.tearDown(error: .connectionClosed)
            return
        }
        #expect(firstAttemptID > 0)
        #expect(secondAttemptID > 0)
        #expect(firstTransport == .debugLoopback)
        #expect(secondTransport == .debugLoopback)
        #expect(connectedID == secondAttemptID)
        #expect(connectedTransport == .debugLoopback)
        await session.tearDown(error: .connectionClosed)
    }

    @Test func mobileShellErrorsProvideStablePrivacySafeClassifications() {
        #expect(MobileShellConnectionError.invalidResponse.diagnosticFailureKind == .protocolViolation)
        #expect(MobileShellConnectionError.connectionClosed.diagnosticFailureKind == .connectionClosed)
        #expect(MobileShellConnectionError.requestTimedOut.diagnosticFailureKind == .timedOut)
        #expect(MobileShellConnectionError.transportWriteTimedOut.diagnosticFailureKind == .timedOut)
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
}
