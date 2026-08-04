import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing

@Suite
struct TranscriptProseContinuityTests {
    private let projector = TranscriptProjector()

    @Test
    func adjacentAssistantProseBlocksBothRenderAsProseRows() {
        let rows = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
            Self.agent(seq: 3, text: "prose B"),
        ])).rows

        #expect(Self.agentText(in: rows, seq: 2) == "prose A")
        #expect(Self.agentText(in: rows, seq: 3) == "prose B")
        #expect(!rows.contains { if case .activitySummary = $0.rowKind { true } else { false } })
    }

    @Test
    func appendingAssistantProseRetainsExistingProseIdentity() throws {
        let first = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
        ]))
        let second = projector.project(TranscriptProjectionInput(entries: [
            Self.user(seq: 1, text: "prompt"),
            Self.agent(seq: 2, text: "prose A"),
            Self.agent(seq: 3, text: "prose B"),
        ]), previousRows: first.rows)
        let retainedID = Self.rowID(seq: 2)
        let appendedID = Self.rowID(seq: 3)

        #expect(try #require(Self.row(in: first.rows, seq: 2)).rowID == retainedID)
        #expect(try #require(Self.row(in: second.rows, seq: 2)).rowID == retainedID)
        #expect(Self.agentText(in: second.rows, seq: 2) == "prose A")
        #expect(second.diff.removed.isEmpty)
        #expect(second.diff.inserted[appendedID] != nil)
    }

    private static let journal = JournalID(rawValue: "prose-continuity")

    private static func user(seq: Int, text: String) -> EntrySnapshot {
        entry(seq: seq, payload: .userMessage(UserMessagePayload(
            text: text,
            attachmentCount: 0,
            hasImage: false
        )))
    }

    private static func agent(seq: Int, text: String) -> EntrySnapshot {
        entry(seq: seq, payload: .agentProse(AgentProsePayload(markdown: text)))
    }

    private static func entry(seq: Int, payload: EntryPayload) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journal,
            seq: EntrySeq(rawValue: seq),
            kind: payload.kind,
            content: EntryContent(contentHash: seq, payload: payload),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }

    private static func rowID(seq: Int) -> TranscriptRowID {
        .entry(journalID: journal, seq: EntrySeq(rawValue: seq))
    }

    private static func row(in rows: [TranscriptRow], seq: Int) -> TranscriptRow? {
        rows.first { $0.rowID == rowID(seq: seq) }
    }

    private static func agentText(in rows: [TranscriptRow], seq: Int) -> String? {
        guard case .proseAgent(let text, _) = row(in: rows, seq: seq)?.rowKind else { return nil }
        return text
    }
}
