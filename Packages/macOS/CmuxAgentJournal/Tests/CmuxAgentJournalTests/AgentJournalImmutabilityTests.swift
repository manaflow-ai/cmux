import Foundation
import SQLite3
import Testing
@testable import CmuxAgentJournal

@Suite("Journal immutability")
struct AgentJournalImmutabilityTests {
    @Test func updateAndDeleteAreRejectedByTriggers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-immutability-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: url)
        _ = try store.append(
            AgentJournalEventDraft(
                eventId: "event-1",
                kind: .turnStarted,
                occurredAtMs: 1,
                source: "claude",
                agentKey: "claude_code",
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString
            )
        )
        store.close()

        // Tamper through a raw second connection: the schema itself (not the
        // Swift wrapper) must reject mutation of committed history.
        var handle: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        let update = sqlite3_exec(handle, "UPDATE agent_journal SET kind = 'agent.turn.completed';", nil, nil, nil)
        #expect(update != SQLITE_OK)
        let delete = sqlite3_exec(handle, "DELETE FROM agent_journal;", nil, nil, nil)
        #expect(delete != SQLITE_OK)

        var countStatement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM agent_journal;", -1, &countStatement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(countStatement) }
        #expect(sqlite3_step(countStatement) == SQLITE_ROW)
        #expect(sqlite3_column_int64(countStatement, 0) == 1)
    }
}
