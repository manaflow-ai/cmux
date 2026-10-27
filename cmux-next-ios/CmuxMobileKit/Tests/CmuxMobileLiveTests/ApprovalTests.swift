import CmuxMobileAgentChat
import CmuxMobileTransport
import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import CmuxMobileLive

/// Phone-signed approvals (verify/phone-approvals.md): the signed bytes match
/// acpmux and cmux-mobile-host byte for byte (same vectors as their Rust tests), and
/// the hub signs an Allow or an answer, never a deny.
@Suite struct ApprovalPayloadTests {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static let answers: JSONValue = .object([
        "Which?": .string("B"),
        "a\"b": .array([.string("x\ny"), .string("\u{1}")]),
        "codex": .object(["answers": .array([.string("é")])]),
    ])

    @Test func canonicalAnswersMatchAcpmux() {
        var text = ""
        ApprovalPayload.canonicalJSON(Self.answers, into: &text)
        #expect(text == #"{"Which?":"B","a\"b":["x\ny","\u0001"],"codex":{"answers":["é"]}}"#)
        #expect(ApprovalPayload.answersDigest(Self.answers) == "44ba30ad88bf4d244b42c361e7ba2a97441780fce0cdfd2a175df95d6e2d6fc8")
        #expect(ApprovalPayload.answersDigest(nil) == "")
    }

    /// Review m9: numbers print as acpmux (serde_json) prints what it read
    /// from this phone's JSON. Expected values come from serde_json 1.x.
    @Test func numbersMatchAcpmux() {
        let cases: [(Double, String)] = [
            (3, "3"), (1e15, "1000000000000000"), (1e16, "1e+16"), (1.5e16, "1.5e+16"),
            (1.2345678901234568e17, "1.2345678901234568e+17"), (0.5, "0.5"), (1e-7, "1e-7"), (-0.0, "-0.0"),
            (1.5e20, "1.5e+20"), (9_007_199_254_740_992, "9007199254740992"), (1e21, "1e+21"), (1e-5, "0.00001"),
            (1e-6, "1e-6"), (0.0001, "0.0001"), (123.456, "123.456"), (-2.5, "-2.5"), (100.25, "100.25"),
            (0.001234, "0.001234"), (12_345_678_901_234.5, "12345678901234.5"), (2e-300, "2e-300"),
            (1.7976931348623157e308, "1.7976931348623157e+308"), (-1e16, "-1e+16"), (-7, "-7"),
        ]
        for (value, expected) in cases {
            #expect(ApprovalPayload.canonicalNumber(value) == expected, "\(value)")
        }
    }

    @Test func payloadMatchesAcpmux() {
        var payload = ApprovalPayload(
            instance: "0123abcd", macDevice: "9f1c2d3e-0000-4000-8000-000000000001",
            approver: "6a7b8c9d-0000-4000-8000-000000000002", session: "sess-1", permission: "perm-7",
            option: "allow_once", nonce: String(repeating: "ab", count: 32), expiresAt: 1_760_000_000)
        #expect(payload.message.starts(with: Data("acpmux-approver-decision-v1\u{0}".utf8)))
        #expect(Self.sha256(payload.message) == "3093d49d440c85bb9f357d0940a5bbd0e822c944fdfe650e9faae0b58afb6c2c")
        payload.answers = Self.answers
        #expect(Self.sha256(payload.message) == "764300d7c596ec827c3d7ffb2b8b5819816151589c5edce1feecd0937b125fe8")
    }

    @Test func linkChallengeMatchesHostd() {
        let payload = LinkAuthPayload(mac: "mac-1", phone: "phone-1", nonce: "n0", identityKey: "04aa", approvalKey: "04bb", action: "pair")
        #expect(Self.sha256(payload.message) == "9b706236232d90e6548bf7de5c624845d5209a65bb08dba15e4561b85fd26ae2")
    }
}

@MainActor
@Suite struct ApprovalHubTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var params: [[String: Any]] = []
        func append(_ p: [String: Any]) { lock.withLock { params.append(p) } }
        var all: [[String: Any]] { lock.withLock { params } }
    }

    /// acpmux with one pending prompt (nonce `n1`, run `inst`) that records each answer.
    static func fakeAcpmux(_ sent: Sent) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"personInstance":"inst"}}}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[]}"#)]
            case "_acpmux/info":
                return [reply(#"{"sessionId":"s1","pending":[{"permissionId":"perm","decisionNonce":"n1","personInstance":"inst","request":{"toolCall":{"title":"rm -rf build"},"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"deny","kind":"reject_once"}]}}]}"#)]
            case "_acpmux/permission_respond":
                sent.append(object["params"] as? [String: Any] ?? [:])
                return [reply("{}")]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func allowIsSignedAfterFaceIDAndDenyIsNot() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(sent).openChannel(service: "acpmux", args: [:]))
        let key = P256.Signing.PrivateKey()
        let reasons = Sent()
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1",
                                          now: { Date(timeIntervalSince1970: 1_000) }) { reason in
            reasons.append(["reason": reason])
            return { message in try key.signature(for: message).rawRepresentation }
        }
        try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
        try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "deny")
        let allow = try #require(sent.all.first)
        let meta = try #require((allow["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])
        #expect(meta["decisionNonce"] as? String == "n1")
        let decision = try #require(meta["approverDecision"] as? [String: Any])
        #expect(decision["approver"] as? String == "phone-1")
        #expect((decision["expiresAt"] as? NSNumber)?.intValue == 1_120)
        let payload = ApprovalPayload(instance: "inst", macDevice: "mac-1", approver: "phone-1", session: "s1",
                                      permission: "perm", option: "allow", nonce: "n1", expiresAt: 1_120)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(hexString: decision["signature"] as? String ?? "")))
        #expect(key.publicKey.isValidSignature(signature, for: payload.message))
        #expect(reasons.all.first?["reason"] as? String == "Allow “rm -rf build”")
        // The deny went unsigned, and Face ID asked once.
        #expect(sent.all.count == 2 && sent.all[1]["_meta"] == nil)
        #expect(reasons.all.count == 1)
    }

    @Test func cancelledFaceIDSendsNothing() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(sent).openChannel(service: "acpmux", args: [:]))
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1") { _ in throw PhoneKeys.Failure.cancelled }
        await #expect(throws: AcpmuxHub.ApprovalCancelled.self) {
            try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
        }
        #expect(sent.all.isEmpty)
    }

    /// Review m9: the signature's expiry starts after Face ID returned, so a
    /// sheet left up for minutes does not send an expired answer.
    @Test func theExpiryStartsAfterFaceID() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux(sent).openChannel(service: "acpmux", args: [:]))
        let clock = Sent()
        clock.append(["now": 1_000])
        let key = P256.Signing.PrivateKey()
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1",
                                          now: { Date(timeIntervalSince1970: TimeInterval(clock.all.last?["now"] as? Int ?? 0)) }) { _ in
            clock.append(["now": 5_000])  // the user took 4000 s to look at Face ID
            return { message in try key.signature(for: message).rawRepresentation }
        }
        try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
        let meta = try #require((sent.all.first?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])
        let decision = try #require(meta["approverDecision"] as? [String: Any])
        #expect((decision["expiresAt"] as? NSNumber)?.intValue == 5_120)
    }

    /// Review m9: an acpmux before phone approvals (no `decisionNonce`) gets
    /// nothing from a paired phone, and the phone says to update the Mac.
    @Test func anOlderMacSaysToUpdate() async throws {
        let sent = Sent()
        let hub = AcpmuxHub()
        let old = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/info":
                return [reply(#"{"sessionId":"s1","pending":[{"permissionId":"perm","request":{"options":[{"optionId":"allow","kind":"allow_once"}]}}]}"#)]
            case "_acpmux/permission_respond":
                sent.append(object["params"] as? [String: Any] ?? [:])
                return [reply("{}")]
            default: return [reply(#"{"sessions":[]}"#)]
            }
        }
        await hub.bind(try await old.openChannel(service: "acpmux", args: [:]))
        hub.approver = AcpmuxHub.Approver(phoneID: "phone-1", macDevice: "mac-1") { _ in
            Issue.record("asked for Face ID")
            return { _ in Data() }
        }
        do {
            try await hub.respond(sessionID: "s1", permissionID: "perm", optionID: "allow")
            Issue.record("expected a refusal")
        } catch {
            #expect(AcpmuxSessionSource.message(error).contains("update cmux on the Mac"))
        }
        #expect(sent.all.isEmpty)
    }

    @Test func faceIDErrorsReadAsPlainWords() {
        let lockout = AcpmuxSessionSource.message(PhoneKeys.Failure.notVerified(LAError.Code.biometryLockout.rawValue))
        #expect(lockout == "Not approved: Face ID is locked. Unlock this iPhone with its passcode, then try again.")
        let passcode = AcpmuxSessionSource.message(PhoneKeys.Failure.notVerified(LAError.Code.passcodeNotSet.rawValue))
        #expect(passcode.contains("set a passcode"))
        #expect(!AcpmuxSessionSource.message(PhoneKeys.Failure.notVerified(-9999)).contains("Code"))
    }
}

private extension Data {
    init?(hexString: String) {
        var out = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
