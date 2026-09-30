import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("ACP wire")
struct ACPWireTests {
    @Test("Decodes requests and preserves numeric and string ids")
    func decodesRequestIdentifiers() {
        guard case .success(let numeric) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#
        ) else {
            Issue.record("The numeric request should decode")
            return
        }
        guard case .success(let string) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0","id":"abc","method":"initialize"}"#
        ) else {
            Issue.record("The string request should decode")
            return
        }

        #expect(numeric.id == .number(7))
        #expect(string.id == .string("abc"))
        #expect(string.params.isEmpty)
    }

    @Test("Decoding reports malformed JSON-RPC envelopes")
    func decodeProblems() {
        guard case .failure(.notJSON) = ACPIncomingMessage.decode(line: "not json") else {
            Issue.record("Invalid JSON should be reported as notJSON")
            return
        }
        guard case .failure(.notAnObject) = ACPIncomingMessage.decode(line: "[]") else {
            Issue.record("A JSON array should be reported as notAnObject")
            return
        }
        guard case .failure(.wrongVersion("1.0")) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"1.0","method":"x"}"#
        ) else {
            Issue.record("Wrong protocol versions should be reported")
            return
        }
        guard case .failure(.missingMethod(nil)) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0"}"#
        ) else {
            Issue.record("A missing method should be reported")
            return
        }
        guard case .failure(.paramsNotAnObject(.number(3))) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0","id":3,"method":"x","params":[]}"#
        ) else {
            Issue.record("Non-object params should be reported with their id")
            return
        }
    }

    @Test("Outgoing envelopes serialize as one stable JSON line")
    func outgoingLineIsStable() throws {
        let line = try #require(ACPOutgoingMessage.line(ACPOutgoingMessage.result(
            id: .string("abc"),
            ["ok": true]
        )))
        #expect(line == #"{"id":"abc","jsonrpc":"2.0","result":{"ok":true}}"#)
    }
}
