import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Reply validity is native request data only. It confers no person gesture: renderer redemption
/// and a fresh current-generation check are separate requirements at the eventual send boundary.
struct AgentPaneQuestionReplyTests {
    static func prompt(harness: String = "claude", allowsOther: Bool = true, multi: Bool = false,
                       label: String = "Glass", preview: String = "<b>preview</b>") -> [String: Any] {
        let options: [[String: Any]] = [["id": "glass", "label": label,
                                        "preview": ["text": preview.trimmingCharacters(in: .whitespacesAndNewlines), "format": "html"]],
                                       ["id": "paper", "label": "Paper"]]
        let question: [String: Any] = ["harness": harness, "items": [
            ["id": "q", "prompt": "Choose?", "options": options, "multiSelect": multi, "allowsOther": allowsOther]]]
        let request: [String: Any] = [
            "options": [["optionId": "yes", "kind": "allow_once"], ["optionId": "no", "kind": "reject_once"]],
            "toolCall": ["toolCallId": "call", "_meta": ["acpmux": ["question": question], "claude": ["tool": "AskUserQuestion"]],
                         "rawInput": ["questions": [["question": "Choose?", "options": [["label": label, "preview": preview],
                                                                                     ["label": "Paper"]]]]]]]
        return ["permissionId": "p", "decisionNonce": AcpmuxPendingQuestionsTests.nonce,
                "personInstance": AcpmuxPendingQuestionsTests.instance, "request": request]
    }

    static func fixture(_ prompt: [String: Any] = prompt()) throws -> (AcpmuxPendingQuestions, AcpmuxPendingQuestions.Question) {
        let ledger = AcpmuxPendingQuestions()
        ledger.reset(connection: 1)
        ledger.observe(AcpmuxPendingQuestionsTests.live(prompt), replyTo: nil, connection: 1)
        return (ledger, try #require(ledger.question(session: "s", permission: "p", connection: 1)))
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func failure(_ object: [String: Any], question: AcpmuxPendingQuestions.Question) throws -> AgentPaneQuestionReply.Failure? {
        let text = try json(object)
        do {
            _ = try AgentPaneQuestionReply(question: question, replyJSON: text)
            return nil
        } catch { return error }
    }

    @Test func claudeOtherPreservesExactTextAndCanonicalIntent() throws {
        let (_, question) = try Self.fixture()
        let text = "Use the existing queue and its lifecycle.\nKeep this answer exactly as typed."
        let body: [String: Any] = ["optionId": "yes", "answers": ["Choose?": text]]
        let reply = try AgentPaneQuestionReply(question: question, replyJSON: Self.json(body))
        #expect(reply.question == question)
        #expect(reply.intent.method == "_acpmux/permission_respond")
        #expect(reply.intent.params["sessionId"] == .string("s"))
        #expect(reply.intent.params["permissionId"] == .string("p"))
        #expect(reply.intent.params["answers"] == AcpmuxSecretKey.canonicalDigest(["Choose?": text]).map(AgentPaneJSONScalar.string))
        #expect(reply.canonicalJSON == AcpmuxSecretKey.canonicalJSON(body))
    }

    @Test func codexAndClaudeRequireTheirOwnCompleteShape() throws {
        let (_, codex) = try Self.fixture(Self.prompt(harness: "codex"))
        let good: [String: Any] = ["optionId": "yes", "answers": ["q": ["answers": ["Other text"]]]]
        #expect(try Self.failure(good, question: codex) == nil)
        for answers: [String: Any] in [
            ["Choose?": "Other text"], ["q": "Other text"], ["q": ["answers": []]],
            ["q": ["answers": [""]]], ["q": ["answers": ["x"], "hidden": true]],
            ["q": ["answers": ["a", "b"]]], ["q": ["answers": [String(repeating: "x", count: 4097)]]],
            ["q": ["answers": ["x"]], "forged": ["answers": ["y"]]]
        ] {
            #expect(try Self.failure(["optionId": "yes", "answers": answers], question: codex) == .answers)
        }
        let (_, claude) = try Self.fixture()
        #expect(try Self.failure(good, question: claude) == .answers)
        #expect(try Self.failure(["optionId": "yes", "answers": [:]], question: claude) == .answers)
    }

    @Test func callerCannotSupplyIdentityOrStalePermissionOption() throws {
        let (_, question) = try Self.fixture()
        let good: [String: Any] = ["optionId": "yes", "answers": ["Choose?": "Other"]]
        for key in ["sessionId", "permissionId", "_meta", "ticket"] {
            var forged = good
            forged[key] = "forged"
            #expect(try Self.failure(forged, question: question) == .malformed)
        }
        #expect(try Self.failure(["optionId": "old-allow", "answers": ["Choose?": "Other"]], question: question) == .option)
        #expect(try Self.failure(["optionId": "no", "answers": ["Choose?": "Other"]], question: question) == .option)
    }

    @Test func currentChoiceContentConstrainsAnswersWhereOtherIsDisabled() throws {
        let (_, question) = try Self.fixture(Self.prompt(allowsOther: false))
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"]], question: question) == nil)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]], question: question) == .answers)
        let (_, codex) = try Self.fixture(Self.prompt(harness: "codex", allowsOther: false))
        #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Other"]]]], question: codex) == .answers)
        let (_, multi) = try Self.fixture(Self.prompt(allowsOther: false, multi: true))
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass, Paper"]], question: multi) == nil)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass, Glass"]], question: multi) == .answers)
    }

    @Test func annotationsUseCurrentNativeRawPreviewsAndNotesBounds() throws {
        let (_, question) = try Self.fixture(Self.prompt(preview: "  <b>preview</b>  "))
        let answers = ["Choose?": "Glass"]
        #expect(try Self.failure(["optionId": "yes", "answers": answers,
                                 "annotations": ["Choose?": ["preview": "<b>preview</b>", "notes": "Useful"]]],
                                question: question) == nil)
        for annotation: [String: Any] in [
            ["Choose?": ["preview": "<b>forged</b>"]], ["other": ["preview": "<b>preview</b>"]],
            ["Choose?": ["hidden": "x"]], ["Choose?": ["notes": " "]],
            ["Choose?": ["notes": String(repeating: "x", count: 8193)]], ["Choose?": [:]], [:]
        ] {
            #expect(try Self.failure(["optionId": "yes", "answers": answers, "annotations": annotation],
                                    question: question) == .annotations)
        }
        let (_, codex) = try Self.fixture(Self.prompt(harness: "codex"))
        #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Glass"]]],
                                 "annotations": ["Choose?": ["notes": "x"]]], question: codex) == .annotations)
    }

    @Test func previewValidationReadsOriginalNativeInputNotOnlyNormalizedItems() throws {
        var prompt = Self.prompt()
        var request = try #require(prompt["request"] as? [String: Any])
        var tool = try #require(request["toolCall"] as? [String: Any])
        // Keep normalized question keys/options/preview unchanged while changing the source
        // preview the owner validates. A retained key set or normalized-only copy is insufficient.
        tool["rawInput"] = ["questions": [["question": "Choose?",
                                          "options": [["label": "Glass", "preview": "<b>native</b>"]]]]]
        request["toolCall"] = tool
        prompt["request"] = request
        let (_, question) = try Self.fixture(prompt)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>preview</b>"]]], question: question) == .annotations)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>native</b>"]]], question: question) == nil)
    }

    @Test func equalKeyReissueCannotValidateOldChoiceOrPreviewAsCurrent() throws {
        let (ledger, first) = try Self.fixture(Self.prompt(allowsOther: false, preview: "<b>old</b>"))
        let oldBody: [String: Any] = ["optionId": "yes", "answers": ["Choose?": "Glass"],
                                      "annotations": ["Choose?": ["preview": "<b>old</b>"]]]
        let captured = try AgentPaneQuestionReply(question: first, replyJSON: Self.json(oldBody))
        ledger.observe(AcpmuxPendingQuestionsTests.live(Self.prompt(allowsOther: false, label: "New", preview: "<b>new</b>"), seq: 11),
                       replyTo: nil, connection: 1)
        let next = try #require(ledger.question(session: "s", permission: "p", connection: 1))
        #expect(next.answerKeys == first.answerKeys)
        #expect(!ledger.isCurrent(captured.question))
        #expect(try Self.failure(oldBody, question: next) == .answers)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "New"],
                                 "annotations": ["Choose?": ["preview": "<b>old</b>"]]], question: next) == .annotations)
    }

    @Test(arguments: [
        #"{"optionId":"yes","optionId":"no","answers":{"Choose?":"Other"}}"#,
        #"{"optionId":"yes","answers":{"Choose?":"first","Choose?":"second"}}"#,
        #"{"optionId":"yes","answers":{"Choose?":"Other"},"annotations":null}"#,
        #"["yes"]"#, #"{"optionId":"yes","answers":"Other"}"#,
        #"{"optionId":"yes","answers":{"Choose?":"Other"}}"# + " trailing"
    ])
    func malformedAndAmbiguousJSONIsRefused(text: String) throws {
        let (_, question) = try Self.fixture()
        #expect(throws: AgentPaneQuestionReply.Failure.self) {
            try AgentPaneQuestionReply(question: question, replyJSON: text)
        }
    }
}
