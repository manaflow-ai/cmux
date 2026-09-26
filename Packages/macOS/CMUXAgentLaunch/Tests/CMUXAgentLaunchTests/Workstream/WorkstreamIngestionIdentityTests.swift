import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
struct WorkstreamIngestionIdentityTests {
    private func event(requestID: String? = "request", session: String = "session", input: String = "{}") -> WorkstreamEvent {
        WorkstreamEvent(sessionId: session, hookEventName: .permissionRequest,
            source: "claude", toolName: "Tool", toolInputJSON: input, requestId: requestID)
    }

    @Test func duplicatePendingAndHandledRequestsKeepOneItem() async throws {
        let store = WorkstreamStore(ringCapacity: 10)
        let firstValue = await store.ingestReturningItem(event())
        let first = try #require(firstValue)
        #expect((await store.ingestReturningItem(event()))?.id == first.id)
        #expect(store.items.count == 1)
        await store.markResolved(first.id, decision: .permission(.once))
        let replayValue = await store.ingestReturningItem(event())
        let replay = try #require(replayValue)
        #expect(replay.id == first.id)
        guard case .resolved(.permission(.once), _) = replay.status else {
            Issue.record("A handled retry must not become pending again")
            return
        }
        #expect(store.items.count == 1)
    }

    @Test func reusedRequestCannotChangePayloadOrSession() async throws {
        let store = WorkstreamStore(ringCapacity: 10)
        let firstValue = await store.ingestReturningItem(event(input: #"{"command":"first"}"#))
        let first = try #require(firstValue)
        #expect(await store.ingestReturningItem(event(input: #"{"command":"different"}"#)) == nil)
        #expect(await store.ingestReturningItem(event(session: "other", input: #"{"command":"first"}"#)) == nil)
        #expect(store.items.map(\.id) == [first.id])
    }

    @Test func identityLessLegacyEventsAreNotMistakenForRetries() async {
        let store = WorkstreamStore(ringCapacity: 10)
        await store.ingest(event(requestID: nil))
        await store.ingest(event(requestID: nil))
        #expect(store.items.count == 2)
    }

    @Test func evictedRequestIdentityCanBeReused() async throws {
        let store = WorkstreamStore(ringCapacity: 1)
        let firstValue = await store.ingestReturningItem(event(requestID: "first"))
        let first = try #require(firstValue)
        _ = await store.ingestReturningItem(event(requestID: "second"))
        let reusedValue = await store.ingestReturningItem(event(requestID: "first"))
        let reused = try #require(reusedValue)
        #expect(reused.id != first.id)
        #expect(store.items.map(\.payload.requestID) == ["first"])
    }
}
