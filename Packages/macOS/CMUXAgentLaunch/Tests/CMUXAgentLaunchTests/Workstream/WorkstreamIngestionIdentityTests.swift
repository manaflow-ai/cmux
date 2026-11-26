import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
struct WorkstreamIngestionIdentityTests {
    private func event(requestID: String? = "request", session: String = "session", input: String = "{}") -> WorkstreamEvent {
        WorkstreamEvent(sessionId: session, hookEventName: .permissionRequest,
            source: "claude", toolName: "Tool", toolInputJSON: input, requestId: requestID)
    }

    @Test func duplicatePendingAndHandledRequestsKeepOneItem() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        let first = try #require(store.ingestReturningItem(event()))
        #expect(store.ingestReturningItem(event())?.id == first.id)
        #expect(store.items.count == 1)
        store.markResolved(first.id, decision: .permission(.once))
        let replay = try #require(store.ingestReturningItem(event()))
        #expect(replay.id == first.id)
        guard case .resolved(.permission(.once), _) = replay.status else {
            Issue.record("A handled retry must not become pending again")
            return
        }
        #expect(store.items.count == 1)
    }

    @Test func reusedRequestCannotChangePayloadOrSession() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        let first = try #require(store.ingestReturningItem(event(input: #"{"command":"first"}"#)))
        #expect(store.ingestReturningItem(event(input: #"{"command":"different"}"#)) == nil)
        #expect(store.ingestReturningItem(event(session: "other", input: #"{"command":"first"}"#)) == nil)
        #expect(store.items.map(\.id) == [first.id])
    }

    @Test func identityLessLegacyEventsAreNotMistakenForRetries() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(event(requestID: nil))
        store.ingest(event(requestID: nil))
        #expect(store.items.count == 2)
    }

    @Test func evictedRequestIdentityCanBeReused() throws {
        let store = WorkstreamStore(ringCapacity: 1)
        let first = try #require(store.ingestReturningItem(event(requestID: "first")))
        _ = store.ingestReturningItem(event(requestID: "second"))
        let reused = try #require(store.ingestReturningItem(event(requestID: "first")))
        #expect(reused.id != first.id)
        #expect(store.items.map(\.payload.requestID) == ["first"])
    }
}
