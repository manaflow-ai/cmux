import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Agent journal session tails")
struct AgentJournalSessionTailTests {
    @Test("a session is ended only when its latest start was followed by an end")
    func endedFollowsLatestStart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-journal-tail-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3")
        let store = try AgentJournalStore(databaseURL: url)
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        func append(_ kind: AgentJournalEventKind, _ session: String, at ms: Int64, subagent: Bool = false) throws {
            _ = try store.append(AgentJournalEventDraft(
                kind: kind,
                occurredAtMs: ms,
                source: "claude",
                agentKey: "claude_code",
                sessionId: session,
                workspaceId: UUID().uuidString,
                surfaceId: UUID().uuidString,
                isSubagent: subagent
            ))
        }
        // Killed mid-turn with the app.
        try append(.sessionStarted, "lost", at: 1_000)
        try append(.turnStarted, "lost", at: 2_000)
        // Quit normally.
        try append(.sessionStarted, "done", at: 1_000)
        try append(.sessionEnded, "done", at: 1_500)
        // Ended once, then resumed and killed.
        try append(.sessionStarted, "resumed", at: 1_000)
        try append(.sessionEnded, "resumed", at: 1_100)
        try append(.sessionStarted, "resumed", at: 1_200)
        // Subagent rows and old rows are ignored.
        try append(.turnStarted, "sub", at: 2_000, subagent: true)
        try append(.turnStarted, "old", at: 10)

        let tails = try store.sessionTails(occurredAtOrAfterMs: 500)
        let byId = Dictionary(uniqueKeysWithValues: tails.map { ($0.sessionId, $0) })
        #expect(Set(byId.keys) == ["lost", "done", "resumed"])
        #expect(byId["lost"]?.hasEnded == false)
        #expect(byId["lost"]?.lastOccurredAtMs == 2_000)
        #expect(byId["done"]?.hasEnded == true)
        #expect(byId["resumed"]?.hasEnded == false)
        #expect(byId["lost"]?.source == "claude")
    }
}
