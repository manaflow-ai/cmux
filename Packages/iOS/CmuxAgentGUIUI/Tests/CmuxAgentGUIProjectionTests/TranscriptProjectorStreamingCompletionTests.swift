import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing

@Suite
struct TranscriptProjectorStreamingCompletionTests {
    @Test
    func durableAgentEntryReplacesStreamingStyle() throws {
        let projector = TranscriptProjector()
        let confirmed = Self.agent(seq: 1, text: "confirmed")
        let streaming = projector.project(TranscriptProjectionInput(
            entries: [confirmed],
            streamingTail: TranscriptStreamingTail(
                journalID: Self.journal,
                afterSeq: EntrySeq(rawValue: 1),
                textTail: "Hello there, happy to help!",
                revision: 1
            )
        ))
        let durable = Self.agent(seq: 2, text: "Hello there, happy to help!")
        let completed = projector.project(
            TranscriptProjectionInput(entries: [confirmed, durable]),
            previousRows: streaming.rows
        )
        let durableID = TranscriptRowID.entry(
            journalID: Self.journal,
            seq: EntrySeq(rawValue: 2)
        )
        let durableRow = try #require(completed.rows.first { $0.rowID == durableID })

        guard case .proseAgent(let text, _) = durableRow.rowKind else {
            Issue.record("completed reply should use durable prose styling")
            return
        }
        #expect(text == "Hello there, happy to help!")
        #expect(completed.rows.allSatisfy { row in
            if case .streaming = row.rowKind { return false }
            return true
        })
        #expect(completed.diff.removed.keys.contains(.streaming(
            journalID: Self.journal,
            afterSeq: EntrySeq(rawValue: 1)
        )))
    }

    private static let journal = JournalID(rawValue: "journal-stream-completion")

    private static func agent(seq: Int, text: String) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journal,
            seq: EntrySeq(rawValue: seq),
            kind: .agentProse,
            content: EntryContent(
                contentHash: seq,
                payload: .agentProse(AgentProsePayload(markdown: text))
            ),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }
}
