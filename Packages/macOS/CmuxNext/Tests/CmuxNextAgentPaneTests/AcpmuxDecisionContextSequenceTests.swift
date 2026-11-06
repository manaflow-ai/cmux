import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A peer's pending notification can lack a log sequence. It stays current over late history,
/// but must not become an infinite sequence that blocks its decision or its next incarnation.
struct AcpmuxDecisionContextSequenceTests {
    private static let oldNonce = String(repeating: "a", count: 64)
    private static let newNonce = String(repeating: "b", count: 64)
    private static let instance = String(repeating: "c", count: 32)

    private static func prompt(_ nonce: String, permission: String = "p1") -> [String: Any] {
        ["permissionId": permission, "decisionNonce": nonce, "personInstance": instance,
         "request": ["options": [["optionId": "yes", "kind": "allow_once"]],
                     "toolCall": ["_meta": ["acpmux": ["question": ["items": [["id": "q1", "prompt": "Which one?"]]]]]]]]
    }

    private static func pending(_ contexts: AcpmuxDecisionContexts, nonce: String = newNonce,
                                permission: String = "p1", seq: UInt64? = nil) {
        var params = prompt(nonce, permission: permission)
        params["sessionId"] = "s"
        if let seq { params["seq"] = seq }
        contexts.observe(["method": "_acpmux/permission_pending", "params": params], replyTo: nil)
    }

    private static func request(_ contexts: AcpmuxDecisionContexts, nonce: String, seq: UInt64,
                                kind: String = "permission_request") {
        let record: [String: Any] = ["dir": "mux", "kind": kind, "sessionId": "s", "seq": seq,
                                     "msg": prompt(nonce)]
        contexts.observe(["result": ["events": [record]]], replyTo: "_acpmux/events")
    }

    private static func decide(_ contexts: AcpmuxDecisionContexts, seq: UInt64, permission: String? = "p1") {
        let msg: [String: Any] = permission.map { ["permissionId": $0] } ?? [:]
        contexts.observe(["method": "_acpmux/event", "params": [
            "dir": "mux", "kind": "permission_decision", "sessionId": "s", "seq": seq, "msg": msg,
        ]], replyTo: nil)
    }

    @Test func anUnsequencedPendingCanBeDecidedAndItsIDReissued() {
        let contexts = AcpmuxDecisionContexts()
        Self.pending(contexts, nonce: Self.oldNonce)
        #expect(contexts.questions(session: "s").count == 1)
        let pendingVersion = contexts.pendingQuestionVersion()
        Self.decide(contexts, seq: 20)
        #expect(contexts.questions(session: "s").isEmpty)
        #expect(contexts.pendingQuestionVersion() > pendingVersion)
        let decidedVersion = contexts.pendingQuestionVersion()
        // The request's historical record cannot resurrect the already decided binding.
        Self.request(contexts, nonce: Self.oldNonce, seq: 10)
        #expect(contexts.context(session: "s", permission: "p1") == nil)
        #expect(contexts.pendingQuestionVersion() == decidedVersion)
        Self.request(contexts, nonce: Self.newNonce, seq: 30, kind: "permission_reissued")
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
        // An old decision arriving later must not clear the newer reissue.
        Self.decide(contexts, seq: 20)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
    }

    @Test func ClaudeAskUserQuestionWithoutNormalizedEnvelopeGetsANativeQuestionContext() {
        let contexts = AcpmuxDecisionContexts()
        let request: [String: Any] = [
            "options": [["optionId": "yes", "kind": "allow_once"]],
            "toolCall": [
                "_meta": ["claude": ["tool": "AskUserQuestion"]],
                "rawInput": ["questions": [["question": "Which one?", "options": [["label": "A"]]]]],
            ],
        ]
        let params: [String: Any] = ["sessionId": "s", "permissionId": "claude-question",
                                     "decisionNonce": Self.newNonce, "personInstance": Self.instance,
                                     "request": request]
        contexts.observe(["method": "_acpmux/permission_pending", "params": params], replyTo: nil)
        #expect(contexts.questions(session: "s")["claude-question"]?.isQuestion == true)
    }

    @Test func ClaudeAskUserQuestionWithoutNormalizedEnvelopeStoresItsAnswerKeys() {
        let options = AcpmuxPermissionOptions()
        options.observe([
            "method": "_acpmux/permission_pending",
            "params": [
                "permissionId": "claude-question",
                "request": [
                    "toolCall": [
                        "_meta": ["claude": ["tool": "AskUserQuestion"]],
                        "rawInput": ["questions": [
                            ["question": "Which one?", "options": [["label": "A"]]],
                            ["question": "Why?", "options": [["label": "Because"]]],
                        ]],
                    ],
                ],
            ],
        ], replyTo: nil)
        #expect(options.questionKeys(permissionId: "claude-question") == Set(["Which one?", "Why?"]))
    }

    @Test func historyCannotReplaceAnUnsequencedPendingUntilItsExactEchoAnchorsIt() {
        let contexts = AcpmuxDecisionContexts()
        Self.pending(contexts)
        let version = contexts.pendingQuestionVersion()
        Self.request(contexts, nonce: Self.oldNonce, seq: 10)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
        #expect(contexts.pendingQuestionVersion() == version)
        // Anchoring the same context changes no binding; older history still cannot replace it.
        Self.request(contexts, nonce: Self.newNonce, seq: 30)
        Self.request(contexts, nonce: Self.oldNonce, seq: 20)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
        #expect(contexts.pendingQuestionVersion() == version)
        Self.decide(contexts, seq: 40)
        #expect(contexts.questions(session: "s").isEmpty)
    }

    @Test func missingSequenceRetainsTheLastKnownLowerBoundAgainstOldDecisions() {
        let contexts = AcpmuxDecisionContexts()
        Self.pending(contexts, nonce: Self.oldNonce, seq: 30)
        Self.pending(contexts, nonce: Self.newNonce)
        Self.decide(contexts, seq: 20)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
        Self.decide(contexts, seq: 40)
        #expect(contexts.questions(session: "s").isEmpty)
        Self.pending(contexts, nonce: Self.oldNonce, seq: 50)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.oldNonce)
    }

    @Test func aSessionDecisionClearsUnsequencedPromptsAndFencesTheirHistory() {
        let contexts = AcpmuxDecisionContexts()
        Self.pending(contexts, permission: "p1")
        Self.pending(contexts, permission: "p2")
        Self.decide(contexts, seq: 20, permission: nil)
        #expect(contexts.questions(session: "s").isEmpty)
        Self.request(contexts, nonce: Self.oldNonce, seq: 10)
        #expect(contexts.questions(session: "s").isEmpty)
        Self.pending(contexts, nonce: Self.newNonce, seq: 30)
        #expect(contexts.questions(session: "s").count == 1)
    }

    @Test func evictingAnUnsequencedContextAlsoEvictsItsReplayMarker() {
        let contexts = AcpmuxDecisionContexts()
        Self.pending(contexts, nonce: Self.oldNonce)
        for index in 0..<AcpmuxDecisionContexts.limit {
            Self.pending(contexts, permission: "other-\(index)")
        }
        #expect(contexts.context(session: "s", permission: "p1") == nil)
        Self.request(contexts, nonce: Self.newNonce, seq: 30)
        #expect(contexts.questions(session: "s")["p1"]?.nonce == Self.newNonce)
    }
}
