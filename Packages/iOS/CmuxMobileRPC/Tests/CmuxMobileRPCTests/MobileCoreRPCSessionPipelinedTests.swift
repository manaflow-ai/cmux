import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCoreRPCSessionPipelinedTests {
    @Test
    func beginSendPreservesWireOrder() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })
        let deadline = Self.deadline()

        try await session.beginSend(
            payload: try Self.request(id: "first"),
            requestID: "first",
            deadlineUptimeNanoseconds: deadline
        )
        try await session.beginSend(
            payload: try Self.request(id: "second"),
            requestID: "second",
            deadlineUptimeNanoseconds: deadline
        )

        await transport.waitUntilSent(count: 2)
        #expect(await transport.sentIDs() == ["first", "second"])
        await session.tearDown(error: .connectionClosed)
    }

    @Test
    func responseCanSettleBeforeAwait() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "settled-first"),
            requestID: "settled-first",
            deadlineUptimeNanoseconds: Self.deadline()
        )
        await transport.waitUntilSent(count: 1)
        try await transport.deliverResponse(
            id: "settled-first",
            status: "settled"
        )
        await Self.waitUntilSettled(
            requestID: "settled-first",
            session: session
        )

        let response = try await session.awaitResponse(
            requestID: "settled-first"
        )
        #expect(try Self.status(response) == "settled")
        await session.tearDown(error: .connectionClosed)
    }

    @Test
    func awaitCanStartBeforeResponseSettles() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "awaiting-first"),
            requestID: "awaiting-first",
            deadlineUptimeNanoseconds: Self.deadline()
        )
        let responseTask = Task {
            try await session.awaitResponse(requestID: "awaiting-first")
        }
        await Self.waitUntilAwaiting(
            requestID: "awaiting-first",
            session: session
        )
        try await transport.deliverResponse(
            id: "awaiting-first",
            status: "awaited"
        )

        #expect(try Self.status(await responseTask.value) == "awaited")
        await session.tearDown(error: .connectionClosed)
    }

    @Test
    func responseTimeoutSettlesPipelinedRequest() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "times-out"),
            requestID: "times-out",
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 10_000_000
        )

        do {
            _ = try await session.awaitResponse(requestID: "times-out")
            Issue.record("Expected the pipelined request to time out")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }
        await session.tearDown(error: .connectionClosed)
    }

    @Test
    func teardownFailsClaimedPipelinedResponse() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "teardown"),
            requestID: "teardown",
            deadlineUptimeNanoseconds: Self.deadline()
        )
        let responseTask = Task {
            try await session.awaitResponse(requestID: "teardown")
        }
        await Self.waitUntilAwaiting(
            requestID: "teardown",
            session: session
        )
        await session.tearDown(error: .connectionClosed)

        do {
            _ = try await responseTask.value
            Issue.record("Expected teardown to fail the pending response")
        } catch MobileShellConnectionError.connectionClosed {
        } catch {
            Issue.record("Expected connectionClosed, got \(error)")
        }
    }

    @Test
    func teardownFailsAndClearsUnclaimedPipelinedResponse() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "unclaimed"),
            requestID: "unclaimed",
            deadlineUptimeNanoseconds: Self.deadline()
        )
        await session.tearDown(error: .connectionClosed)

        // The unclaimed slot must retain the REAL teardown failure so a later
        // response() reports connectionClosed, not a protocol error.
        #expect(await session.pipelinedPending["unclaimed"] != nil)
        #expect(await session.requestTimeoutTasks["unclaimed"] == nil)
        do {
            _ = try await session.awaitResponse(requestID: "unclaimed")
            Issue.record("Expected the torn-down response handle to fail")
        } catch MobileShellConnectionError.connectionClosed {
        } catch {
            Issue.record("Expected connectionClosed, got \(error)")
        }
        // Claiming the settlement releases the slot.
        #expect(await session.pipelinedPending["unclaimed"] == nil)
    }

    @Test
    func cancellingAwaitResponseCancelsPendingRequest() async throws {
        let transport = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { transport })

        try await session.beginSend(
            payload: try Self.request(id: "cancelled"),
            requestID: "cancelled",
            deadlineUptimeNanoseconds: Self.deadline()
        )
        let responseTask = Task {
            try await session.awaitResponse(requestID: "cancelled")
        }
        await Self.waitUntilAwaiting(
            requestID: "cancelled",
            session: session
        )
        responseTask.cancel()

        do {
            _ = try await responseTask.value
            Issue.record("Expected response cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await session.pipelinedPending["cancelled"] == nil)
        await session.tearDown(error: .connectionClosed)
    }

    private static func request(id: String) throws -> Data {
        try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: ["text": id],
            id: id
        )
    }

    private static func status(_ data: Data) throws -> String? {
        let payload = try JSONSerialization.jsonObject(with: data)
        return (payload as? [String: String])?["status"]
    }

    private static func deadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000
    }

    private static func waitUntilAwaiting(
        requestID: String,
        session: MobileCoreRPCSession
    ) async {
        for _ in 0..<1_000 {
            if case .awaiting? = await session.pipelinedPending[requestID] {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(requestID) to be claimed")
    }

    private static func waitUntilSettled(
        requestID: String,
        session: MobileCoreRPCSession
    ) async {
        for _ in 0..<1_000 {
            if case .settled? = await session.pipelinedPending[requestID] {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(requestID) to settle")
    }
}
