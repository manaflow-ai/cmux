import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Home's signer for a Chief question answer (`signQuestionDecision`), over a real checked Unix
/// connection with same-connection person proof (``HiddenHomeApprovalTests/FakeAcpmux``). It
/// signs only the prompt it reads itself, and only answers that prompt takes.
@MainActor @Suite(.serialized) struct HomeQuestionDecisionSignerTests {
    typealias FakeAcpmux = HiddenHomeApprovalTests.FakeAcpmux
    static let nonce = String(repeating: "a", count: 64)

    static let request: [String: Any] = [
        "toolCall": ["_meta": ["acpmux": ["question": ["harness": "chief", "items": [[
            "id": "q0", "prompt": "Which auth method?", "multiSelect": false, "allowsOther": false,
            "options": [["id": "oauth", "label": "OAuth"], ["id": "keys", "label": "API keys"]]]]]]]],
        "options": [["optionId": "answer", "kind": "allow_once"], ["optionId": "skip", "kind": "reject_once"]],
    ]

    private func fixture(proof: Bool = true) throws -> (AcpmuxApprovalAnswerer, FakeAcpmux, String) {
        let socket = "/tmp/hqd-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let key = proof ? AcpmuxPersonKey.spawnKey(for: socket) : AcpmuxPersonKey.newKey()
        let server = try FakeAcpmux(socket: socket, key: key, connections: 1)
        var info = server.info
        info["pending"] = [["permissionId": "p1", "personInstance": "0123456789abcdef", "decisionNonce": Self.nonce,
                            "request": Self.request]]
        server.info = info
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let env = AcpmuxEnvironment(executable: URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath(),
            home: URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent), socketPath: socket,
            daemonArguments: [], childEnvironment: [:])
        return (AcpmuxApprovalAnswerer(environment: env, chiefHomeID: "abcdef12"), server, key)
    }

    /// The daemon's `conversation-question-decision` reply for `answers`.
    static func unsigned(answers: [String: Any] = ["Which auth method?": "API keys"], nonce: String = nonce,
                         session: String = "s1", request: [String: Any] = request) throws -> String {
        let digest = try #require(AcpmuxSecretKey.canonicalDigest(request))
        let reply: [String: Any] = ["session": session, "permission": "p1", "option_id": "answer",
                                    "instance": "0123456789abcdef", "decision_nonce": nonce, "answers": answers,
                                    "question": ["harness": "chief", "session": "local/" + session, "permission": "p1"],
                                    "request": request, "request_json": try #require(AcpmuxSecretKey.canonicalJSON(request)),
                                    "digest": digest]
        return String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
    }

    /// acpmux `decision_answers_proof`, written out here rather than calling the app's.
    static func expectedProof(key: String, answers: String) -> String {
        let bytes = Array(key.utf8)
        let keyBytes = stride(from: 0, to: bytes.count, by: 2).compactMap { UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16) }
        let answersDigest = SHA256.hash(data: Data(answers.utf8)).map { String(format: "%02x", $0) }.joined()
        let message = Data("acpmux-person-decision-answers-v1\u{0}0123456789abcdef\u{0}s1\u{0}p1\u{0}answer\u{0}\(nonce)\u{0}\(answersDigest)".utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func signsTheLivePromptsExactAnswersThroughTheClick() async throws {
        let (answerer, server, key) = try fixture()
        defer { server.stop() }
        let clicks = Clicks()
        let outcome = await answerer.signQuestionDecision(try Self.unsigned(), through: { body in clicks.spend(body) })
        guard case .signed(let text) = outcome else { Issue.record("not signed: \(outcome)"); return }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(envelope.keys) == ["question", "request_json", "digest", "instance", "option_id", "decision_nonce", "person_decision"])
        #expect(envelope["person_decision"] as? String == Self.expectedProof(key: key, answers: #"{"Which auth method?":"API keys"}"#))
        #expect(envelope["decision_nonce"] as? String == Self.nonce)
        #expect(envelope["request_json"] as? String == AcpmuxSecretKey.canonicalJSON(Self.request))
        #expect(envelope["digest"] as? String == AcpmuxSecretKey.canonicalDigest(Self.request))
        #expect(clicks.spent == 1)
        // Signing answers nothing: the conversation owner delivers the answer with the proof.
        #expect(!server.methods.contains("_acpmux/permission_respond"))
    }

    @Test func aChangedOrSpentPromptIsExpired() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        let other = await answerer.signQuestionDecision(try Self.unsigned(nonce: String(repeating: "b", count: 64)),
                                                       through: { _ in Issue.record("a stale nonce reached the click"); return false })
        #expect(other == .expired)
    }

    @Test func anAnswerThePromptDoesNotTakeIsRefused() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        let outcome = await answerer.signQuestionDecision(try Self.unsigned(answers: ["Which auth method?": "rm -rf"]),
                                                         through: { _ in Issue.record("a foreign answer reached the click"); return false })
        #expect(outcome == .refused)
    }

    @Test func aRefusedClickSignsNothing() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        #expect(await answerer.signQuestionDecision(try Self.unsigned(), through: { _ in false }) == .refused)
    }

    @Test func anUnprovenAppSignsNothing() async throws {
        let (answerer, server, _) = try fixture(proof: false)
        defer { server.stop() }
        let outcome = await answerer.signQuestionDecision(try Self.unsigned(),
                                                         through: { _ in Issue.record("an unproven line reached the click"); return false })
        #expect(outcome == .refused)
    }

    @Test func anotherDaemonsPromptIsNotHere() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        let outcome = await answerer.signQuestionDecision(try Self.unsigned(session: "s2"),
                                                         through: { _ in Issue.record("another chat's prompt reached the click"); return false })
        #expect(outcome == .notHere)
    }

    /// The signed identity is the raw local id: a qualified or path-like session in the reply is
    /// refused unread, and the proof binds the raw one (`expectedProof`).
    @Test func aSessionThatIsNotARawLocalIDIsRefusedUnread() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        for session in ["local/s1", "peer/s1", "a/b", ""] {
            #expect(await answerer.signQuestionDecision(try Self.unsigned(session: session),
                                                       through: { _ in Issue.record("\(session) reached the click"); return false }) == .refused)
        }
    }

    @Test func aReplyWhoseRequestIsNotItsDigestIsRefusedUnread() async throws {
        var reply = try #require(try JSONSerialization.jsonObject(with: Data(try Self.unsigned().utf8)) as? [String: Any])
        reply["digest"] = String(repeating: "0", count: 64)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        #expect(await answerer.signQuestionDecision(text, through: { _ in false }) == .refused)
        // The fake takes one connection: the refusal above opened none, so this read gets it.
        guard case .signed = await answerer.signQuestionDecision(try Self.unsigned(), through: { body in body(); return true }) else {
            Issue.record("the refused reply used the daemon's connection"); return
        }
        #expect(server.connections == 1)
    }

    /// The envelope carries the request's canonical text, exactly as the daemon returned and the
    /// signer verified it: an integer past 2^53 signs and stays exact in `request_json`.
    @Test func aRequestWithAWideIntegerIsCarriedAsItsCanonicalText() async throws {
        var request = Self.request
        request["toolCall"] = ["_meta": (Self.request["toolCall"] as? [String: Any])?["_meta"] ?? [:], "rawInput": ["at": 9_007_199_254_740_993]]
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        var info = server.info
        info["pending"] = [["permissionId": "p1", "personInstance": "0123456789abcdef", "decisionNonce": Self.nonce, "request": request]]
        server.info = info
        let reply = try Self.unsigned(request: request)
        guard case .signed(let signed) = await answerer.signQuestionDecision(reply, through: { body in body(); return true }) else {
            Issue.record("a wide integer was refused"); return
        }
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(signed.utf8)) as? [String: Any])
        let text = try #require(envelope["request_json"] as? String)
        #expect(text.contains("9007199254740993"))
        #expect(text == AcpmuxSecretKey.canonicalJSON(request))
        #expect(envelope["digest"] as? String == AcpmuxSecretKey.canonicalDigest(request))
        #expect(envelope["request"] == nil)
    }

    /// An integer past what the app can write exactly (above u64 or Int64) has no canonical form
    /// here: the reply is refused before the click, never signed with a rounded number.
    @Test func aRequestIntegerTheAppCannotWriteExactlyIsRefused() async throws {
        let (answerer, server, _) = try fixture()
        defer { server.stop() }
        for wide in ["18446744073709551617", "123456789012345678901234567890"] {
            let text = #"{"at":\#(wide),"options":[]}"#
            let reply: [String: Any] = ["session": "s1", "permission": "p1", "option_id": "answer",
                                        "instance": "0123456789abcdef", "decision_nonce": Self.nonce,
                                        "answers": ["Which auth method?": "API keys"], "question": ["harness": "chief"],
                                        "request_json": text,
                                        // The daemon hashes the text it sends: only the canonical check can refuse it.
                                        "digest": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
            #expect(await answerer.signQuestionDecision(json, through: { _ in Issue.record("\(wide) reached the click"); return false }) == .refused)
        }
    }

    /// One native click's write claims, counted.
    nonisolated final class Clicks: @unchecked Sendable { // crash-allow: `count` is read and written under `lock`
        private let lock = NSLock()
        private var count = 0
        var spent: Int { lock.withLock { count } }
        func spend(_ body: () -> Void) -> Bool {
            lock.withLock { count += 1 }
            body()
            return true
        }
    }
}
