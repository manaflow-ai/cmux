import Testing
import CmuxAgentReplica
import Foundation
@testable import CmuxAgentWire

@Suite struct ReplicaGoldenTests {
    @Test func agentSessionSnapshotEncodingIsPinned() throws {
        try WireTestSupport.assertGolden(
            WireTestSupport.session,
            json: WireTestSupport.sessionJSON
        )
    }

    @Test func entrySnapshotEncodingIsPinned() throws {
        try WireTestSupport.assertGolden(
            WireTestSupport.entry,
            json: WireTestSupport.entryJSON
        )
    }

    @Test func entryPayloadEncodingIsPinned() throws {
        try WireTestSupport.assertGolden(
            WireTestSupport.entryPayload,
            json: WireTestSupport.entryPayloadJSON
        )
    }

    @Test func sendTicketEncodingIsPinned() throws {
        try WireTestSupport.assertGolden(
            WireTestSupport.ticket,
            json: WireTestSupport.ticketJSON
        )
    }

    @Test func pendingAskEncodingIsPinned() throws {
        try WireTestSupport.assertGolden(
            WireTestSupport.ask,
            json: WireTestSupport.askJSON
        )
    }

    @Test func pendingAskDecodesLegacyCountOnlyShape() throws {
        let data = Data(#"{"id":"ask-1","kind":"question","options_count":2,"prompt_summary":"Choose","session_id":"session-1","state":{"type":"active"}}"#.utf8)
        let ask = try JSONDecoder().decode(PendingAsk.self, from: data)

        #expect(ask.options.isEmpty)
        #expect(ask.optionsCount == 2)
    }
}
