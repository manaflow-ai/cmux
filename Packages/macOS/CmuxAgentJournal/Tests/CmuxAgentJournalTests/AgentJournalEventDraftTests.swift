import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Event draft wire format")
struct AgentJournalEventDraftTests {
    @Test func validationCatchesBadDrafts() {
        var draft = AgentJournalEventDraft(
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString
        )
        #expect(draft.validationProblem() == nil)

        draft.source = "Not A Slug"
        #expect(draft.validationProblem() != nil)
        draft.source = "claude"

        draft.workspaceId = "not-a-uuid"
        #expect(draft.validationProblem() != nil)
        draft.workspaceId = UUID().uuidString

        // A guessed target and an unattributed reason are mutually exclusive.
        draft.unattributedReason = "target-unresolved"
        #expect(draft.validationProblem() != nil)
        draft.workspaceId = nil
        draft.surfaceId = nil
        #expect(draft.validationProblem() == nil)
    }

    @Test func detailIsBounded() {
        let long = String(repeating: "x", count: 2_000)
        let draft = AgentJournalEventDraft(
            kind: .turnCompleted,
            occurredAtMs: 1,
            source: "codex",
            agentKey: "codex",
            detail: long
        )
        #expect(draft.detail?.count == AgentJournalEventDraft.maximumDetailLength)
    }

    @Test func jsonRoundTripsWithSnakeCaseKeys() throws {
        let draft = AgentJournalEventDraft(
            eventId: "event-1",
            kind: .approvalRequested,
            occurredAtMs: 123,
            source: "grok",
            agentKey: "grok",
            sessionId: "s",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            isSubagent: true,
            pendingWork: true,
            nativeEvent: "Notification",
            detail: "d"
        )
        let data = try JSONEncoder().encode(draft)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"event_id\""))
        #expect(json.contains("\"agent_key\""))
        #expect(json.contains("\"occurred_at_ms\""))
        let decoded = try JSONDecoder().decode(AgentJournalEventDraft.self, from: data)
        #expect(decoded == draft)
    }
}
