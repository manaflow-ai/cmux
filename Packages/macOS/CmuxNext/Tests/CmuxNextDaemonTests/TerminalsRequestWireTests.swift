import Foundation
import Testing
@testable import CmuxNextDaemon

/// The Requests/Terminals family on the wire: `list-terminals` sends no fields and is ungated, and its
/// reply decodes to the registry list. The request is generated from cmux-tui/spec/sdk-schema.json;
/// this holds the JSON the hand-written type sent.
struct TerminalsRequestWireTests {
    @Test func aListSendsOnlyTheEnvelope() throws {
        let raw = try WireCoding.encodeRequest(ListTerminalsRequest(), id: 1)
        #expect(String(decoding: raw, as: UTF8.self) == #"{"cmd":"list-terminals","id":1}"#)
        #expect(ListTerminalsRequest.requiredCapability == nil)
    }

    @Test func theReplyIsTheRegistryList() throws {
        let line = Data(#"{"ok":true,"data":{"terminals":[{"terminal_id":"term_1","workspace_key":"w","lifecycle":"live"}]}}"#.utf8)
        let list = try WireCoding.decodeResponse(ListTerminalsRequest.Response.self, from: line)
        #expect(list.terminals == [TerminalRegistryEntry(terminalID: "term_1", workspaceKey: "w", lifecycle: "live", exit: nil)])
    }
}
