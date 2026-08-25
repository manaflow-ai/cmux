import Foundation
import SQLite3
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

    private func withStore(_ body: (AgentJournalStore, URL) throws -> Void) throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try body(store, url)
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
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let first = try store.append(draft())
        let second = try store.append(draft())
        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(!first.replayed && !second.replayed)
        #expect(try store.headSequence() == 2)
        store.close()
    }

    @Test func appendIsIdempotentByEventId() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let event = draft(eventId: "stable-id")
        let first = try store.append(event)
        let replay = try store.append(event)
        #expect(replay.sequence == first.sequence)
        #expect(replay.replayed)
        #expect(try store.events(afterSequence: 0, limit: 10).count == 1)
        store.close()
    }

    @Test func appendRejectsSameIdWithDifferentContent() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        _ = try store.append(draft(eventId: "stable-id", kind: .turnStarted))
        do {
            _ = try store.append(draft(eventId: "stable-id", kind: .turnCompleted))
            Issue.record("same-id retry with different content must throw idempotencyConflict")
        } catch AgentJournalStoreError.idempotencyConflict {
            // Expected: the receipt guard, not some unrelated storage error.
        }
        // The rejected append must not have written anything.
        #expect(try store.headSequence() == 1)
        #expect(try store.events(afterSequence: 0, limit: 10).count == 1)
        store.close()
    }

    @Test func appendRejectsGuessedTargets() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        var bad = draft()
        bad.unattributedReason = "target-unresolved"
        do {
            _ = try store.append(bad)
            Issue.record("a reason plus a target must be rejected as an invalid draft")
        } catch AgentJournalStoreError.invalidDraft {
            // Expected: admission validation, not some unrelated storage error.
        }
        // The rejected append must not have written anything.
        #expect(try store.headSequence() == 0)
        #expect(try store.events(afterSequence: 0, limit: 10).isEmpty)
        store.close()
    }

    @Test func unattributedEventsAreDurable() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        var diagnostic = draft(surfaceId: nil, workspaceId: nil)
        diagnostic.unattributedReason = "target-unresolved"
        let outcome = try store.append(diagnostic)
        let events = try store.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
        #expect(events[0].sequence == outcome.sequence)
        #expect(events[0].draft.unattributedReason == "target-unresolved")
        store.close()
        // Diagnostics are durable: an independent reopen still reads them.
        let reopened = try AgentJournalStore(databaseURL: url)
        defer { reopened.close() }
        let reread = try reopened.events(afterSequence: 0, limit: 10)
        #expect(reread.count == 1)
        #expect(reread[0].draft == diagnostic)
    }

    @Test func roundTripsAllFields() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
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
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outcome = try store.append(draft())
        store.close()
        let reopened = try AgentJournalStore(databaseURL: url)
        defer { reopened.close() }
        #expect(try reopened.headSequence() == outcome.sequence)
        let events = try reopened.events(afterSequence: 0, limit: 10)
        #expect(events.count == 1)
    }

    @Test func surfaceAliasChainsResolve() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
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
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let old = UUID().uuidString
        let new = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [old: new], surfaceAliases: [:])
        #expect(try store.resolvedWorkspaceId(old) == new)
        store.close()
    }

    @Test func aliasCyclesTerminate() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let a = UUID().uuidString
        let b = UUID().uuidString
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [a: b])
        try store.recordRestoreAliases(workspaceAliases: [:], surfaceAliases: [b: a])
        // Chain following is bounded; a recorded cycle fails closed with nil
        // rather than returning an arbitrary intermediate identity.
        #expect(try store.resolvedSurfaceId(a) == nil)
        store.close()
    }

    @Test func readsPageBySequence() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        for _ in 0..<5 { _ = try store.append(draft()) }
        let firstPage = try store.events(afterSequence: 0, limit: 2)
        #expect(firstPage.map(\.sequence) == [1, 2])
        let rest = try store.events(afterSequence: 2, limit: 10)
        #expect(rest.map(\.sequence) == [3, 4, 5])
        store.close()
    }

    @Test func readPageAdvancesOverUndecodableRows() throws {
        try withStore { store, url in
            _ = try store.append(draft())
            // A row written by a hypothetical newer schema: valid SQL, but a
            // kind this build cannot decode. INSERT is allowed by design —
            // only UPDATE/DELETE are trigger-blocked.
            var handle: OpaquePointer?
            defer { sqlite3_close_v2(handle) }
            try #require(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            let insert = """
            INSERT INTO agent_journal(
                event_id, schema_version, kind, occurred_at_ms, committed_at_ms,
                source, agent_key, is_subagent, pending_work, unattributed_reason
            ) VALUES ('future-1', 2, 'agent.future.kind', 1, 1, 'claude', 'claude_code', 0, 0, 'x');
            """
            #expect(sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK)
            _ = try store.append(draft())

            let page = try store.readPage(afterSequence: 0, limit: 10)
            #expect(page.events.map(\.sequence) == [1, 3])
            #expect(page.skippedSequences == [2])
            #expect(page.scannedThroughSequence == 3)

            // Pagination cannot stall on an undecodable run: a page that
            // decodes nothing still advances the cursor.
            let onlyBad = try store.readPage(afterSequence: 1, limit: 1)
            #expect(onlyBad.events.isEmpty)
            #expect(onlyBad.scannedThroughSequence == 2)
            #expect(!onlyBad.isEmpty)
        }
    }

    @Test func closedStoreThrows() throws {
        let (store, url) = try makeStore()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        store.close()
        #expect(throws: AgentJournalStoreError.closed) {
            _ = try store.headSequence()
        }
    }

}
