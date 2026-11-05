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

    @Test func retryAfterRingEvictionsResolvesToTheLiveItem() throws {
        let store = WorkstreamStore(ringCapacity: 3)
        var latestByRequest: [String: UUID] = [:]
        for index in 0..<10 {
            let requestID = "request-\(index)"
            let item = try #require(store.ingestReturningItem(event(requestID: requestID)))
            latestByRequest[requestID] = item.id
        }
        #expect(store.items.map(\.payload.requestID) == ["request-7", "request-8", "request-9"])
        for index in 7..<10 {
            let requestID = "request-\(index)"
            #expect(store.ingestReturningItem(event(requestID: requestID))?.id == latestByRequest[requestID])
        }
        #expect(store.items.count == 3)
        let reused = try #require(store.ingestReturningItem(event(requestID: "request-0")))
        #expect(reused.id != latestByRequest["request-0"])
        #expect(store.items.map(\.payload.requestID) == ["request-8", "request-9", "request-0"])
    }

    @Test func retryFindsHandledItemAmongManyInterleavedRequests() throws {
        let store = WorkstreamStore(ringCapacity: 2_000)
        for index in 0..<1_999 {
            store.ingest(event(requestID: "request-\(index)", session: "session-\(index % 7)"))
        }
        let target = try #require(store.items.first)
        store.markResolved(target.id, decision: .permission(.once))
        let replay = try #require(store.ingestReturningItem(event(requestID: "request-0", session: "session-0")))
        #expect(replay.id == target.id)
        guard case .resolved = replay.status else {
            Issue.record("A retry must return the stored item with its current status")
            return
        }
        #expect(store.items.count == 1_999)
    }

    @Test func retryResolvesItemsFromLoadedAndPagedHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-identity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let persistence = WorkstreamPersistence(fileURL: url)
        var persistedIDs: [UUID] = []
        for index in 0..<5 {
            let item = WorkstreamItem(
                workstreamId: "session-\(index)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(
                    requestId: "request-\(index)", toolName: "Tool", toolInputJSON: "{}", pattern: nil
                )
            )
            persistedIDs.append(item.id)
            try await persistence.append(item)
        }
        let store = WorkstreamStore(
            persistence: persistence, ringCapacity: 5, initialLoadLimit: 2, historyPageSize: 2
        )
        await store.start()
        #expect(store.ingestReturningItem(event(requestID: "request-4", session: "session-4"))?.id == persistedIDs[4])
        await store.loadOlderItems()
        #expect(store.items.count == 4)
        #expect(store.ingestReturningItem(event(requestID: "request-1", session: "session-1"))?.id == persistedIDs[1])
        #expect(store.ingestReturningItem(event(requestID: "request-3", session: "session-3"))?.id == persistedIDs[3])

        // Two fresh requests evict the two oldest paged rows; the rest stay addressable.
        _ = store.ingestReturningItem(event(requestID: "fresh-a"))
        _ = store.ingestReturningItem(event(requestID: "fresh-b"))
        #expect(store.items.map(\.payload.requestID) == ["request-2", "request-3", "request-4", "fresh-a", "fresh-b"])
        #expect(store.ingestReturningItem(event(requestID: "request-2", session: "session-2"))?.id == persistedIDs[2])
        let reused = try #require(store.ingestReturningItem(event(requestID: "request-1", session: "session-1")))
        #expect(reused.id != persistedIDs[1])
        await store.flushPersistence()
    }
}
