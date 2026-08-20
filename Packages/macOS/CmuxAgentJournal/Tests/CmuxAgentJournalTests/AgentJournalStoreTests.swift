import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Agent journal store")
struct AgentJournalStoreTests {
    private func makeStore() throws -> (AgentJournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("journal.sqlite3")
        return (try AgentJournalStore(databaseURL: url), url)
    }

    private func draft(
        eventId: String = UUID().uuidString,
        kind: AgentJournalEventKind = .turnStarted,
        surfaceId: String? = UUID().uuidString,
        workspaceId: String? = UUID().uuidString
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            eventId: eventId,
            kind: kind,
            occurredAtMs: 1_000,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    @Test func appendAssignsMonotonicSequences() throws {
        let (store, _) = makeStoreOrFail()
        let first = try store.append(draft())
        let second = try store.append(draft())
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(!first.replayed && !second.replayed)
        #expect(try store.headSequence() == 2)
        store.close()
    }

    @Test func appendIsIdempotentByEventId() throws {
        let (store, _) = makeStoreOrFail()
        let event = draft(eventId: "stable-id")
        let first = try store.append(event)
        let replay = try store.append(event)
        #expect(replay.sequence == first.sequence)
        #expect(replay.replayed)
        #expect(try store.events(afterSequence: 0, limit: 10).count == 1)
        store.close()
    }

    @Test func appendRejectsSameIdWithDifferentContent() throws {
        let (store, _) = makeStoreOrFail()
        _ = try store.append(draft(eventId: "stable-id", kind: .turnStarted))
        #expect(throws: AgentJournalStoreError.self) {
            _ = try store.append(draft(eventId: "stable-id", kind: .turnCompleted))
        }
        store.close()
    }

    @Test func appendRejectsGuessedTargets() throws {
        let (store, _) = makeStoreOrFail()
        var bad = draft()
        bad.unattributedReason = "target-unresolved"
        #expect(throws: AgentJournalStoreError.self) {
            _ = try store.append(bad)
        }
        store.close()
    }

    @Test func unattributedEventsAreDurable() throws {
        let (store, _) = makeStoreOrFail()
        var diagnostic = draft(surfaceId: nil, workspaceId: nil)
        diagnostic.unattributedReason = "target-unresolved"
        let outcome = try store.append(diagnostic)
        let events = try store.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
        #expect(events[0].sequence == outcome.sequence)
        #expect(events[0].draft.unattributedReason == "target-unresolved")
        store.close()
    }

    @Test func roundTripsAllFields() throws {
        let (store, _) = makeStoreOrFail()
        var event = draft(kind: .turnCompleted)
        event.pendingWork = true
        event.isSubagent = true
        event.nativeEvent = "Stop"
        event.detail = "did things"
        event.declaredPhase = .running
        _ = try store.append(event, committedAt: Date(timeIntervalSince1970: 42))
        let read = try #require(try store.events(afterSequence: 0, limit: 1).first)
        #expect(read.draft == event)
        #expect(read.committedAtMs == 42_000)
        store.close()
    }

    @Test func journalIsAppendOnlyAcrossReopen() throws {
        let (store, url) = makeStoreOrFail()
        let outcome = try store.append(draft())
        store.close()
        let reopened = try AgentJournalStore(databaseURL: url)
        #expect(try reopened.headSequence() == outcome.sequence)
        let events = try reopened.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
        reopened.close()
    }

    @Test func surfaceAliasChainsResolve() throws {
        let (store, _) = makeStoreOrFail()
        let a = UUID().uuidString
        let b = UUID().uuidString
        let c = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [a: b])
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [b: c])
        #expect(try store.resolvedSurfaceId(a) == c)
        #expect(try store.resolvedSurfaceId(b) == c)
        #expect(try store.resolvedSurfaceId(c) == c)
        let unknown = UUID().uuidString
        #expect(try store.resolvedSurfaceId(unknown) == unknown)
        store.close()
    }

    @Test func workspaceAliasResolves() throws {
        let (store, _) = makeStoreOrFail()
        let old = UUID().uuidString
        let new = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [old: new], surfaceAliases: [:])
        #expect(try store.resolvedWorkspaceId(old) == new)
        store.close()
    }

    @Test func aliasCyclesTerminate() throws {
        let (store, _) = makeStoreOrFail()
        let a = UUID().uuidString
        let b = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [a: b])
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [b: a])
        // Chain following is bounded; the resolved id is one of the cycle
        // members rather than an infinite loop.
        let resolved = try store.resolvedSurfaceId(a)
        #expect(resolved == a || resolved == b)
        store.close()
    }

    @Test func readsPageBySequence() throws {
        let (store, _) = makeStoreOrFail()
        for _ in 0..<5 { _ = try store.append(draft()) }
        let firstPage = try store.events(afterSequence: 0, limit: 2)
        #expect(firstPage.map(\.sequence) == [1, 2])
        let rest = try store.events(afterSequence: 2, limit: 10)
        #expect(rest.map(\.sequence) == [3, 4, 5])
        store.close()
    }

    @Test func closedStoreThrows() throws {
        let (store, _) = makeStoreOrFail()
        store.close()
        #expect(throws: AgentJournalStoreError.closed) {
            _ = try store.headSequence()
        }
    }

    private func makeStoreOrFail() -> (AgentJournalStore, URL) {
        do {
            return try makeStore()
        } catch {
            fatalError("failed to open test store: \(error)")
        }
    }
}
