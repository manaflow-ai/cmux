import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("ACP wire")
struct ACPWireTests {
    private func success(_ result: Result<ACPIncomingMessage, ACPIncomingMessage.Problem>) -> ACPIncomingMessage? {
        guard case .success(let message) = result else { return nil }
        return message
    }

    @Test("Decodes requests and preserves numeric and string ids")
    func decodesRequestIdentifiers() throws {
        let numeric = try #require(success(ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#
        )))
        let string = try #require(success(ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"2.0","id":"abc","method":"initialize"}"#
        )))

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

    @Test("Error codes keep ACP's assignments and cmux's codes out of their way")
    func errorCodesMatchTheProtocol() {
        // The assignments come from `agent-client-protocol-schema/src/v1/error.rs`.
        let assignedByACP: Set<Int> = [
            -32700, -32600, -32601, -32602, -32603, -32800, -32000, -32002,
        ]
        #expect(ACPErrorCode.parseError.rawValue == -32700)
        #expect(ACPErrorCode.invalidRequest.rawValue == -32600)
        #expect(ACPErrorCode.methodNotFound.rawValue == -32601)
        #expect(ACPErrorCode.invalidParams.rawValue == -32602)
        #expect(ACPErrorCode.internalError.rawValue == -32603)
        #expect(ACPErrorCode.requestCancelled.rawValue == -32800)
        #expect(ACPErrorCode.authRequired.rawValue == -32000)
        #expect(ACPErrorCode.resourceNotFound.rawValue == -32002)
        #expect(ACPErrorCode.hostUnavailable.rawValue == -32001)
        #expect(ACPErrorCode.sessionNotFound.rawValue == -32003)
        let values = ACPErrorCode.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count)

        // cmux's own codes sit in the -32000 to -32099 block ACP reserves for
        // agent-defined failures, on values ACP itself does not use.
        for code in [ACPErrorCode.hostUnavailable, .sessionNotFound] {
            #expect(
                assignedByACP.contains(code.rawValue) == false,
                "\(code) took a code ACP has already assigned"
            )
        }

        // Nothing may sit outside both sets.
        for code in ACPErrorCode.allCases {
            #expect(
                assignedByACP.contains(code.rawValue) || (-32099 ... -32000).contains(code.rawValue),
                "\(code) is neither an ACP assignment nor inside ACP's reserved range"
            )
        }
    }

    @Test("Outgoing envelopes serialize as one stable JSON line")
    func outgoingLineIsStable() throws {
        let line = try #require(ACPOutgoingMessage.result(
            id: .string("abc"),
            ["ok": true]
        ).jsonLine)
        #expect(line == #"{"id":"abc","jsonrpc":"2.0","result":{"ok":true}}"#)
    }

    @Test("Outgoing error messages encode their raw error code")
    func outgoingErrorUsesRawCode() throws {
        let envelope = ACPOutgoingMessage.failure(
            id: nil,
            code: .parseError,
            message: "Invalid JSON.",
            data: nil
        ).envelope
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPErrorCode.parseError.rawValue)
        #expect(envelope["id"] is NSNull)
    }
}
