import Testing
import CmuxAgentReplica
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
}
