import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Testing

@testable import CmuxAgentGUIUI

@Suite("Agent transcript row selection resolver")
struct AgentTranscriptRowSelectionResolverTests {
    @Test("activity row taps resolve against current rows")
    func activityRowTapsResolveAgainstCurrentRows() throws {
        let details = Self.activityDetails()
        let rows = [
            AgentTranscriptRenderRow(id: "activity-row", content: .activity(details)),
        ]

        let resolved = try #require(AgentTranscriptRowSelectionResolver.activity(
            rowID: "activity-row",
            rows: rows
        ))

        #expect(resolved == details)
    }

    @Test("stale activity row taps fail closed")
    func staleActivityRowTapsFailClosed() {
        let rows = [
            AgentTranscriptRenderRow(id: "replacement-row", content: .metadata("Updated")),
        ]

        #expect(AgentTranscriptRowSelectionResolver.activity(rowID: "activity-row", rows: rows) == nil)
    }

    @Test("ask and failed ticket taps resolve by row identity")
    func askAndFailedTicketTapsResolveByRowIdentity() throws {
        let ask = PendingAsk(
            id: "ask-1",
            sessionID: AgentSessionID(rawValue: "session"),
            kind: .question,
            promptSummary: "Choose",
            options: ["A", "B"],
            state: .active
        )
        let ticketID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let ticket = SendTicket(
            id: ticketID,
            sessionID: AgentSessionID(rawValue: "session"),
            text: "retry me",
            attachmentCount: 0,
            state: .failed(code: "offline"),
            createdAt: 1
        )
        let rows = [
            AgentTranscriptRenderRow(id: "ask-row", content: .ask(ask)),
            AgentTranscriptRenderRow(id: "ticket-row", content: .pendingTicket(ticket)),
        ]

        #expect(try #require(AgentTranscriptRowSelectionResolver.ask(rowID: "ask-row", rows: rows)) == ask)
        #expect(try #require(AgentTranscriptRowSelectionResolver.failedTicket(
            rowID: "ticket-row",
            rows: rows
        )) == ticket)
    }

    private static func activityDetails() -> TranscriptActivityDetails {
        let journalID = JournalID(rawValue: "selection")
        let turnID = TranscriptTurnID(
            journalID: journalID,
            promptSeq: EntrySeq(rawValue: 1),
            segmentAnchorSeq: EntrySeq(rawValue: 1)
        )
        return TranscriptActivityDetails(
            turnID: turnID,
            summary: TranscriptActivitySummary(
                editedFileCount: 0,
                readFileCount: 0,
                searchedCode: false,
                listedFiles: false,
                commandCount: 0,
                eventCount: 1,
                items: [
                    TranscriptActivityItem(
                        id: .entry(journalID: journalID, seq: EntrySeq(rawValue: 2)),
                        kind: .unknown("event"),
                        summary: "Processed event",
                        isRunning: false
                    ),
                ]
            )
        )
    }
}
