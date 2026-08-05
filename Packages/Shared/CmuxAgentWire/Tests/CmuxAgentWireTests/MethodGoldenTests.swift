import Foundation
import Testing
import CmuxAgentReplica
@testable import CmuxAgentWire

@Suite struct MethodGoldenTests {
    @Test func helloParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiHelloParams(protocolMin: 1, protocolMax: 2, clientCaps: [GuiWireCaps.entriesPaging]),
            json: #"{"client_caps":["entries-paging"],"protocol_max":2,"protocol_min":1}"#
        )
        try WireTestSupport.assertGolden(
            GuiHelloResult(
                protocol: 1,
                serverCaps: [GuiWireCaps.sendTickets, GuiWireCaps.answers],
                epoch: WireTestSupport.epoch,
                macDeviceID: WireTestSupport.mac,
                serverTimeMS: 1_725_000_000_123
            ),
            json: #"{"epoch":"epoch-1","mac_device_id":"mac-1","protocol":1,"server_caps":["send-tickets","answers"],"server_time_ms":1725000000123}"#
        )
    }

    @Test func sessionsParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(GuiSessionsParams(), json: #"{}"#)
        try WireTestSupport.assertGolden(
            GuiSessionsResult(epoch: WireTestSupport.epoch, sessions: [WireTestSupport.session]),
            json: #"{"epoch":"epoch-1","sessions":[\#(WireTestSupport.sessionJSON)]}"#
        )
    }

    @Test func sessionParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiSessionParams(sessionID: WireTestSupport.sessionID),
            json: #"{"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiSessionResult(epoch: WireTestSupport.epoch, session: WireTestSupport.session),
            json: #"{"epoch":"epoch-1","session":\#(WireTestSupport.sessionJSON)}"#
        )
    }

    @Test func entriesParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiEntriesParams(
                sessionID: WireTestSupport.sessionID,
                journalID: WireTestSupport.journalID,
                beforeSeq: EntrySeq(rawValue: 20),
                afterSeq: EntrySeq(rawValue: 9),
                limit: 50
            ),
            json: #"{"after_seq":9,"before_seq":20,"journal_id":"journal-1","limit":50,"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiEntriesResult(
                journalID: WireTestSupport.journalID,
                entries: [WireTestSupport.entry],
                windowStart: EntrySeq(rawValue: 10),
                windowEnd: EntrySeq(rawValue: 10),
                tailSeq: EntrySeq(rawValue: 12),
                hasMoreBefore: true
            ),
            json: #"{"entries":[\#(WireTestSupport.entryJSON)],"has_more_before":true,"journal_id":"journal-1","tail_seq":12,"window_end":10,"window_start":10}"#
        )
    }

    @Test func cursorEntriesAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiEntriesParams(
                sessionID: WireTestSupport.sessionID,
                journalID: WireTestSupport.journalID,
                anchor: .before,
                cursor: JournalCursor(rawValue: "opaque-start"),
                limit: 50
            ),
            json: #"{"anchor":"before","cursor":"opaque-start","journal_id":"journal-1","limit":50,"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiEntriesResult(
                journalID: WireTestSupport.journalID,
                entries: [WireTestSupport.entry],
                windowStart: EntrySeq(rawValue: 10),
                windowEnd: EntrySeq(rawValue: 10),
                tailSeq: EntrySeq(rawValue: 12),
                hasMoreBefore: true,
                hasMoreAfter: true,
                startCursor: JournalCursor(rawValue: "start"),
                endCursor: JournalCursor(rawValue: "end"),
                tailCursor: JournalCursor(rawValue: "tail"),
                requiresPagingRestart: true
            ),
            json: #"{"end_cursor":"end","entries":[\#(WireTestSupport.entryJSON)],"has_more_after":true,"has_more_before":true,"journal_id":"journal-1","requires_paging_restart":true,"start_cursor":"start","tail_cursor":"tail","tail_seq":12,"window_end":10,"window_start":10}"#
        )
    }

    @Test func sendParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiSendParams(
                sessionID: WireTestSupport.sessionID,
                ticketID: "11111111-1111-1111-1111-111111111111",
                text: "Queue this",
                attachments: [GuiSendAttachment(kind: "image", byteCount: 2048)]
            ),
            json: #"{"attachments":[{"byte_count":2048,"kind":"image"}],"session_id":"session-1","text":"Queue this","ticket_id":"11111111-1111-1111-1111-111111111111"}"#
        )
        try WireTestSupport.assertGolden(
            GuiSendResult(accepted: true, queuedOnMac: true),
            json: #"{"accepted":true,"queued_on_mac":true}"#
        )
    }

    @Test func interruptParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiInterruptParams(sessionID: WireTestSupport.sessionID, hard: true),
            json: #"{"hard":true,"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiInterruptResult(interrupted: true),
            json: #"{"interrupted":true}"#
        )
    }

    @Test func answerParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiAnswerParams(sessionID: WireTestSupport.sessionID, askID: "ask-1", choiceIndex: 1),
            json: #"{"ask_id":"ask-1","choice_index":1,"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiAnswerResult(answered: true),
            json: #"{"answered":true}"#
        )
    }

    @Test func capabilitiesParamsAndResultAreGoldenAndRoundTrip() throws {
        try WireTestSupport.assertGolden(
            GuiCapabilitiesParams(sessionID: WireTestSupport.sessionID),
            json: #"{"session_id":"session-1"}"#
        )
        try WireTestSupport.assertGolden(
            GuiCapabilitiesResult(
                tier: .degraded,
                reasons: [
                    GuiCapabilityReason(code: "hooks_disabled", detail: "Safe mode"),
                    GuiCapabilityReason(code: "cli_too_old"),
                ],
                cliVersion: "0.128.0",
                steerable: false,
                answerable: true
            ),
            json: #"{"answerable":true,"cli_version":"0.128.0","reasons":[{"code":"hooks_disabled","detail":"Safe mode"},{"code":"cli_too_old"}],"steerable":false,"tier":"degraded"}"#
        )
    }

    @Test func unknownFieldsAreIgnoredAndMissingOptionalsDefaultToNil() throws {
        let data = Data(#"{"session_id":"session-1","ticket_id":"ticket-1","future":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GuiSendParams.self, from: data)

        #expect(decoded == GuiSendParams(sessionID: WireTestSupport.sessionID, ticketID: "ticket-1"))
    }
}
