import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileRPCDialQuarantineTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func staleDialCannotBlockFreshRouteOwnerOrEmitTwoOutcomes(cancelCaller: Bool) async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59129)
        let key = MobileRPCConnectAttemptKey(route: route)
        let hung = HungRPCDialTransport()
        let clock = RPCDialDeadlineGate()
        let events = AsyncStream<MobileRPCTransportConnectEvent>.makeStream()
        let old = MobileCoreRPCSession(connectAttemptKey: key, connectAttemptRegistry: registry,
                                      makeTransport: { hung }, diagnosticTransport: .iroh,
                                      transportConnectObserver: { _ = events.continuation.yield($0) },
                                      taskTimeout: RPCTaskTimeout(sleep: { _ in try await clock.waitForExpiration() }))
        let payload = try MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "old")
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        let first = Task {
            do {
                _ = try await old.send(payload: payload, requestID: "old", deadlineUptimeNanoseconds: deadline)
                return DiagnosticFailureKind.unknown
            } catch { return DiagnosticFailureKind.classify(error) }
        }
        await hung.waitUntilStarted()
        await clock.waitUntilArmed()
        if cancelCaller { first.cancel() } else { await clock.expire() }
        #expect(await first.value == (cancelCaller ? .cancelled : .timedOut))

        let responding = ControllableResponseTransport(closeEndsReceive: true, automaticallyRespondingRequestIDs: ["fresh"])
        let fresh = MobileCoreRPCSession(connectAttemptKey: key, connectAttemptRegistry: registry,
                                        makeTransport: { responding }, diagnosticTransport: .iroh,
                                        transportConnectObserver: { _ = events.continuation.yield($0) })
        let freshPayload = try MobileCoreRPCClient.requestData(method: "mobile.host.status", id: "fresh")
        let response = try await fresh.send(payload: freshPayload, requestID: "fresh", deadlineUptimeNanoseconds: deadline)
        #expect(!response.isEmpty, "a new owner must connect while the previous native dial is still suspended")
        await hung.release()
        await hung.waitUntilLateCandidateClosed()
        await fresh.tearDown(error: .connectionClosed)
        events.continuation.finish()
        var recorded: [MobileRPCTransportConnectEvent] = []
        for await event in events.stream { recorded.append(event) }
        #expect(recorded.count == 4)
        guard recorded.count == 4 else { return }
        guard case let .attempt(oldID, _) = recorded[0],
              case let .cancelled(cancelledID, _, reason, _) = recorded[1],
              case let .attempt(newID, _) = recorded[2],
              case let .connected(connectedID, _, _, _) = recorded[3] else {
            Issue.record("Each started dial must have exactly one terminal outcome")
            return
        }
        #expect(oldID == cancelledID)
        #expect(newID == connectedID)
        #expect(oldID != newID)
        #expect(reason == (cancelCaller ? .requestCancelled : .requestTimedOut))
    }
}
