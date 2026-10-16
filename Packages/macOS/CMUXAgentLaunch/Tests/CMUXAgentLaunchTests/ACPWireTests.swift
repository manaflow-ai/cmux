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
        guard case .failure(.wrongVersion("1.0", nil)) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"1.0","method":"x"}"#
        ) else {
            Issue.record("Wrong protocol versions should be reported")
            return
        }
        guard case .failure(.wrongVersion("1.0", .number(4))) = ACPIncomingMessage.decode(
            line: #"{"jsonrpc":"1.0","id":4,"method":"x"}"#
        ) else {
            Issue.record("A wrong version must keep the id it could read")
            return
        }
        guard case .failure(.wrongVersion(nil, .string("z"))) = ACPIncomingMessage.decode(
            line: #"{"id":"z","method":"x"}"#
        ) else {
            Issue.record("A missing jsonrpc member must keep the id it could read")
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
        // -32000 to -32099 is JSON-RPC 2.0's range for implementation-defined
        // server errors, not a range ACP defines. ACP takes -32000 and -32002
        // from it; cmux's own codes take free values in the same range so they
        // cannot collide with a future ACP assignment outside it.
        let jsonRPCServerErrors = -32099 ... -32000
        #expect(ACPErrorCode.parseError.rawValue == -32700)
        #expect(ACPErrorCode.invalidRequest.rawValue == -32600)
        #expect(ACPErrorCode.methodNotFound.rawValue == -32601)
        #expect(ACPErrorCode.invalidParams.rawValue == -32602)
        #expect(ACPErrorCode.internalError.rawValue == -32603)
        #expect(ACPErrorCode.requestCancelled.rawValue == -32800)
        #expect(ACPErrorCode.authRequired.rawValue == -32000)
        #expect(ACPErrorCode.resourceNotFound.rawValue == -32002)
        #expect(ACPErrorCode.hostUnavailable.rawValue == -32001)

        // An unknown session answers with ACP's resourceNotFound. A cmux-only
        // code would reach a client as an opaque `Other(_)` it cannot match.
        #expect(ACPErrorCode.allCases.map(\.rawValue).contains(-32003) == false)

        // cmux's own codes take values ACP itself does not use, inside
        // JSON-RPC's server-error range.
        let cmuxCodes: [ACPErrorCode] = [.hostUnavailable]
        for code in cmuxCodes {
            #expect(
                assignedByACP.contains(code.rawValue) == false,
                "\(code) took a code ACP has already assigned"
            )
            #expect(
                jsonRPCServerErrors.contains(code.rawValue),
                "\(code) sits outside JSON-RPC's implementation-defined range"
            )
        }

        // Every remaining code is one ACP assigns. This is the check that
        // reddens if a cmux code is added without being listed above, rather
        // than one a new ACP code outside the range would break.
        for code in ACPErrorCode.allCases where cmuxCodes.contains(code) == false {
            #expect(
                assignedByACP.contains(code.rawValue),
                "\(code) is neither an ACP assignment nor a listed cmux code"
            )
        }
    }

    @Test("A notification envelope carries no id")
    func notificationEnvelopeHasNoIdentifier() throws {
        // This is the shape of every session/update the host sends, so the
        // envelope is pinned even though the replay path builds its own params.
        let message = ACPOutgoingMessage.notification(
            method: ACPHostMethod.sessionUpdate.rawValue,
            params: ["sessionId": "session-1"]
        )
        let envelope = message.envelope
        #expect(envelope["jsonrpc"] as? String == "2.0")
        #expect(envelope["method"] as? String == "session/update")
        #expect((envelope["params"] as? [String: Any])?["sessionId"] as? String == "session-1")
        #expect(envelope.keys.contains("id") == false)
        // Sorted keys and unescaped slashes, the same framing rules the
        // response line test pins.
        #expect(try #require(message.jsonLine)
            == #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1"}}"#)
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
