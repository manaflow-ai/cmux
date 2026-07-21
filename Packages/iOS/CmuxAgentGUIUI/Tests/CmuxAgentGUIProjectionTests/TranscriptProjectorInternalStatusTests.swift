import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing

@Suite
struct TranscriptProjectorInternalStatusTests {
    @Test
    func knownInternalStatusesAreFilteredWhileUnknownAndUserVisibleStatusesFailOpen() {
        let journalID = JournalID(rawValue: "internal-statuses")
        let entries = [
            Self.entry(journalID: journalID, seq: 1, payload: .userMessage(
                UserMessagePayload(text: "prompt", attachmentCount: 0, hasImage: false)
            )),
            Self.status(journalID: journalID, seq: 2, code: .sessionMeta),
            Self.status(journalID: journalID, seq: 3, code: .other("stop_hook_summary")),
            Self.status(journalID: journalID, seq: 4, code: .apiError),
            Self.entry(journalID: journalID, seq: 5, payload: .unknown(
                UnknownPayload(rawKind: "future-event", summary: "preserved")
            )),
            Self.entry(journalID: journalID, seq: 6, payload: .agentProse(
                AgentProsePayload(markdown: "answer")
            )),
        ]

        let rows = TranscriptProjector().project(TranscriptProjectionInput(
            entries: entries,
            sessionPhase: .working
        )).rows

        #expect(Self.row(seq: 2, journalID: journalID, in: rows) == nil)
        #expect(Self.row(seq: 3, journalID: journalID, in: rows) == nil)
        let activityIDs = rows.compactMap { row -> [TranscriptRowID]? in
            guard case .activitySummary(let summary) = row.rowKind else { return nil }
            return summary.items.map(\.id)
        }.flatMap { $0 }
        #expect(activityIDs.contains(.entry(journalID: journalID, seq: EntrySeq(rawValue: 4))))
        #expect(activityIDs.contains(.entry(journalID: journalID, seq: EntrySeq(rawValue: 5))))
        #expect(Self.row(seq: 6, journalID: journalID, in: rows)?.agentText == "answer")
    }

    private static func status(journalID: JournalID, seq: Int, code: StatusCode) -> EntrySnapshot {
        entry(
            journalID: journalID,
            seq: seq,
            payload: .status(StatusPayload(code: code, detail: code.rawValue))
        )
    }

    private static func entry(journalID: JournalID, seq: Int, payload: EntryPayload) -> EntrySnapshot {
        EntrySnapshot(
            journalID: journalID,
            seq: EntrySeq(rawValue: seq),
            kind: payload.kind,
            content: EntryContent(contentHash: seq, payload: payload),
            version: EntityVersion(rawValue: UInt64(seq))
        )
    }

    private static func row(
        seq: Int,
        journalID: JournalID,
        in rows: [TranscriptRow]
    ) -> TranscriptRow? {
        rows.first { $0.rowID == .entry(journalID: journalID, seq: EntrySeq(rawValue: seq)) }
    }
}

private extension TranscriptRow {
    var isActivityItem: Bool {
        if case .activityItem = rowKind { return true }
        return false
    }

    var agentText: String? {
        if case .proseAgent(let text, _) = rowKind { return text }
        return nil
    }
}
