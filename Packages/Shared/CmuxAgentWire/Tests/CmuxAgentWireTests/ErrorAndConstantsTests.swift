import Foundation
import Testing
import CmuxAgentReplica
@testable import CmuxAgentWire

@Suite struct ErrorAndConstantsTests {
    @Test(arguments: [
        ("invalid_params", GuiWireErrorCode.invalidParams),
        ("unsupported_protocol", GuiWireErrorCode.unsupportedProtocol),
        ("not_found", GuiWireErrorCode.notFound),
        ("binding_lost", GuiWireErrorCode.bindingLost),
        ("input_queue_full", GuiWireErrorCode.inputQueueFull),
        ("process_exited", GuiWireErrorCode.processExited),
        ("send_rejected", GuiWireErrorCode.sendRejected),
        ("rate_limited", GuiWireErrorCode.rateLimited),
        ("internal_error", GuiWireErrorCode.internalError),
    ])
    func knownErrorCodesMapFromRPC(rawValue: String, expected: GuiWireErrorCode) throws {
        let error = GuiWireError(code: rawValue, message: "Message")

        #expect(error.code == expected)
        try WireTestSupport.assertGolden(
            error,
            json: #"{"code":"\#(rawValue)","message":"Message"}"#
        )
    }

    @Test func unknownErrorCodeFailsOpenAndRoundTrips() throws {
        let error = GuiWireError(code: "future_error", message: "Future")

        #expect(error.code == .unknown("future_error"))
        try WireTestSupport.assertGolden(
            error,
            json: #"{"code":"future_error","message":"Future"}"#
        )
    }

    @Test func methodTopicAndCapabilityConstantsArePinned() {
        #expect(GuiWireMethod.hello == "gui.v1.hello")
        #expect(GuiWireMethod.sessions == "gui.v1.sessions")
        #expect(GuiWireMethod.session == "gui.v1.session")
        #expect(GuiWireMethod.entries == "gui.v1.entries")
        #expect(GuiWireMethod.send == "gui.v1.send")
        #expect(GuiWireMethod.interrupt == "gui.v1.interrupt")
        #expect(GuiWireMethod.answer == "gui.v1.answer")
        #expect(GuiWireMethod.capabilities == "gui.v1.capabilities")
        #expect(GuiWireTopic.sessions == "gui.v1.sessions")
        #expect(GuiWireTopic.journalPrefix == "gui.v1.journal.")
        #expect(GuiWireTopic.journal(sessionID: WireTestSupport.sessionID) == "gui.v1.journal.session-1")
        #expect(GuiWireCaps.entriesPaging == "entries-paging")
        #expect(GuiWireCaps.sendTickets == "send-tickets")
        #expect(GuiWireCaps.answers == "answers")
        #expect(GuiWireCaps.capabilitiesReport == "capabilities-report")
    }
}
