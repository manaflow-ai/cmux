import Foundation
import Testing
import CmuxAgentReplica
@testable import CmuxAgentWire

@Suite struct EventGoldenTests {
    @Test func sessionUpsertedFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                payload: .sessionUpserted(GuiSessionUpsertedEvent(session: WireTestSupport.session))
            ),
            json: #"{"epoch":"epoch-1","kind":"session_upserted","payload":{"session":\#(WireTestSupport.sessionJSON)}}"#
        )
    }

    @Test func sessionRemovedFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                payload: .sessionRemoved(GuiSessionRemovedEvent(
                    sessionID: WireTestSupport.sessionID,
                    version: EntityVersion(rawValue: 4)
                ))
            ),
            json: #"{"epoch":"epoch-1","kind":"session_removed","payload":{"session_id":"session-1","version":4}}"#
        )
    }

    @Test func entriesAppendedFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .entriesAppended(GuiEntriesAppendedEvent(
                    journalID: WireTestSupport.journalID,
                    entries: [WireTestSupport.entry]
                ))
            ),
            json: #"{"epoch":"epoch-1","kind":"entries_appended","payload":{"entries":[\#(WireTestSupport.entryJSON)],"journal_id":"journal-1"},"session_id":"session-1"}"#
        )
    }

    @Test func entryReplacedFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .entryReplaced(GuiEntryReplacedEvent(
                    journalID: WireTestSupport.journalID,
                    entry: WireTestSupport.entry
                ))
            ),
            json: #"{"epoch":"epoch-1","kind":"entry_replaced","payload":{"entry":\#(WireTestSupport.entryJSON),"journal_id":"journal-1"},"session_id":"session-1"}"#
        )
    }

    @Test func journalResetFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .journalReset(GuiJournalResetEvent(
                    sessionID: WireTestSupport.sessionID,
                    newJournalID: JournalID(rawValue: "journal-2"),
                    tailSeq: EntrySeq(rawValue: 44)
                ))
            ),
            json: #"{"epoch":"epoch-1","kind":"journal_reset","payload":{"new_journal_id":"journal-2","session_id":"session-1","tail_seq":44},"session_id":"session-1"}"#
        )
    }

    @Test func sendStateFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .sendState(GuiSendStateEvent(ticket: WireTestSupport.ticket))
            ),
            json: #"{"epoch":"epoch-1","kind":"send_state","payload":{"ticket":\#(WireTestSupport.ticketJSON)},"session_id":"session-1"}"#
        )
    }

    @Test func askStateFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .askState(GuiAskStateEvent(ask: WireTestSupport.ask))
            ),
            json: #"{"epoch":"epoch-1","kind":"ask_state","payload":{"ask":\#(WireTestSupport.askJSON)},"session_id":"session-1"}"#
        )
    }

    @Test func streamTickFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(
                epoch: WireTestSupport.epoch,
                sessionID: WireTestSupport.sessionID,
                payload: .streamTick(GuiStreamTickEvent(
                    journalID: WireTestSupport.journalID,
                    afterSeq: EntrySeq(rawValue: 10),
                    textTail: "Working",
                    revision: 2
                ))
            ),
            json: #"{"epoch":"epoch-1","kind":"stream_tick","payload":{"after_seq":10,"journal_id":"journal-1","revision":2,"text_tail":"Working"},"session_id":"session-1"}"#
        )
    }

    @Test func unknownFrameIsGoldenAndRoundTrips() throws {
        try WireTestSupport.assertGolden(
            GuiEventFrame(epoch: WireTestSupport.epoch, payload: .unknown("future_kind")),
            json: #"{"epoch":"epoch-1","kind":"future_kind","payload":{}}"#
        )
    }

    @Test func unknownKindAndExtraFieldsDecodeWithoutThrowing() throws {
        let data = Data(#"{"epoch":"epoch-1","extra":true,"kind":"future_kind","payload":{"opaque":1},"session_id":"session-1"}"#.utf8)
        let decoded = try JSONDecoder().decode(GuiEventFrame.self, from: data)

        #expect(decoded == GuiEventFrame(
            epoch: WireTestSupport.epoch,
            sessionID: WireTestSupport.sessionID,
            payload: .unknown("future_kind")
        ))
    }

    @Test func malformedKnownPayloadFailsOpenToUnknownKind() throws {
        let data = Data(#"{"epoch":"epoch-1","kind":"entry_replaced","payload":{"journal_id":"journal-1"}}"#.utf8)
        let decoded = try JSONDecoder().decode(GuiEventFrame.self, from: data)

        #expect(decoded.payload == .unknown("entry_replaced"))
    }
}
