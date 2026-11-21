import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Reply validity is native request data only. It confers no person gesture: renderer redemption
/// and a fresh current-generation check are separate requirements at the eventual send boundary.
struct AgentPaneQuestionReplyTests {
    static func prompt(harness: String = "claude", allowsOther: Any? = true, multi: Any? = false,
                       label: String = "Glass", preview: String = "<b>preview</b>") -> [String: Any] {
        let options: [[String: Any]] = [["id": "glass", "label": label,
                                        "preview": ["text": preview.trimmingCharacters(in: .whitespacesAndNewlines), "format": "html"]],
                                       ["id": "paper", "label": "Paper"]]
        var item: [String: Any] = ["id": "q", "prompt": "Choose?", "options": options]
        if let multi { item["multiSelect"] = multi }
        if let allowsOther { item["allowsOther"] = allowsOther }
        let question: [String: Any] = ["harness": harness, "items": [item]]
        let request: [String: Any] = [
            "options": [["optionId": "yes", "kind": "allow_once"], ["optionId": "no", "kind": "reject_once"]],
            "toolCall": ["toolCallId": "call", "_meta": ["acpmux": ["question": question], "claude": ["tool": "AskUserQuestion"]],
                         "rawInput": ["questions": [["question": "Choose?", "options": [["label": label, "preview": preview],
                                                                                     ["label": "Paper"]]]]]]]
        return ["request": request]
    }

    static func fixture(_ prompt: [String: Any] = prompt()) throws -> AgentPaneQuestionReply.Input {
        let request = try #require(prompt["request"] as? [String: Any])
        return AgentPaneQuestionReply.Input(sessionId: "s", permissionId: "p",
            requestJSON: try #require(AcpmuxSecretKey.canonicalJSON(request)),
            requestDigest: try #require(AcpmuxSecretKey.canonicalDigest(request)))
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func failure(_ object: [String: Any], question: AgentPaneQuestionReply.Input) throws -> AgentPaneQuestionReply.Failure? {
        let text = try json(object)
        do {
            _ = try AgentPaneQuestionReply(input: question, replyJSON: text)
            return nil
        } catch { return error }
    }

    @Test func claudeOtherPreservesExactTextAndCanonicalIntent() throws {
        let question = try Self.fixture()
        let text = "Use the existing queue and its lifecycle.\nKeep this answer exactly as typed."
        let body: [String: Any] = ["optionId": "yes", "answers": ["Choose?": text]]
        let reply = try AgentPaneQuestionReply(input: question, replyJSON: Self.json(body))
        #expect(reply.input == question)
        #expect(reply.intent.method == "_acpmux/permission_respond")
        #expect(reply.intent.params["sessionId"] == .string("s"))
        #expect(reply.intent.params["permissionId"] == .string("p"))
        #expect(reply.intent.params["answers"] == AcpmuxSecretKey.canonicalDigest(["Choose?": text]).map(AgentPaneJSONScalar.string))
        #expect(reply.canonicalJSON == AcpmuxSecretKey.canonicalJSON(body))
    }

    @Test(arguments: ["claude", "chief", "codex"])
    func omittedOrNullAllowsOtherDefaultsToFreeText(harness: String) throws {
        // Options remain present: omission must not silently make this a choice-only question.
        let text = "Keep this Other answer exactly as typed."
        let answers: [String: Any] = harness == "codex"
            ? ["q": ["answers": [text]]] : ["Choose?": text]
        let flags: [Any?] = [nil, NSNull()]
        for flag in flags {
            let question = try Self.fixture(Self.prompt(harness: harness, allowsOther: flag))
            let body: [String: Any] = ["optionId": "yes", "answers": answers]
            let reply = try AgentPaneQuestionReply(input: question, replyJSON: Self.json(body))
            #expect(reply.intent.params["answers"] == AcpmuxSecretKey.canonicalDigest(answers).map(AgentPaneJSONScalar.string))
            #expect(reply.canonicalJSON == AcpmuxSecretKey.canonicalJSON(body))
        }
    }

    @Test func malformedAllowsOtherCannotEnableFreeText() throws {
        let flags: [Any] = ["true", ["enabled": true], 0, 1]
        for flag in flags {
            let question = try Self.fixture(Self.prompt(allowsOther: flag))
            for answer in ["Other", "Glass"] {
                #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": answer]],
                                        question: question) == .answers)
            }
        }
    }

    @Test func multiSelectUsesStrictBooleanAndDefaultsToFalse() throws {
        let malformed: [Any] = [0, 1, "true", ["enabled": true]]
        for flag in malformed {
            let question = try Self.fixture(Self.prompt(harness: "codex", multi: flag))
            #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Other"]]]],
                                    question: question) == .answers)
        }
        let omittedOrNull: [Any?] = [nil, NSNull()]
        for flag in omittedOrNull {
            let question = try Self.fixture(Self.prompt(harness: "codex", multi: flag))
            #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Other"]]]],
                                    question: question) == nil)
            #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Glass", "Paper"]]]],
                                    question: question) == .answers)
        }
    }

    @Test func codexAndClaudeRequireTheirOwnCompleteShape() throws {
        let codex = try Self.fixture(Self.prompt(harness: "codex"))
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
        let claude = try Self.fixture()
        #expect(try Self.failure(good, question: claude) == .answers)
        #expect(try Self.failure(["optionId": "yes", "answers": [:]], question: claude) == .answers)
    }

    @Test func callerCannotSupplyIdentityOrStalePermissionOption() throws {
        let question = try Self.fixture()
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
        let question = try Self.fixture(Self.prompt(allowsOther: false))
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"]], question: question) == nil)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]], question: question) == .answers)
        let codex = try Self.fixture(Self.prompt(harness: "codex", allowsOther: false))
        #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Other"]]]], question: codex) == .answers)
        let multi = try Self.fixture(Self.prompt(allowsOther: false, multi: true))
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass, Paper"]], question: multi) == nil)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass, Glass"]], question: multi) == .answers)
        // Codex answers with each chosen option's label, so two options sharing a label repeat it.
        let codexMulti = try Self.fixture(Self.prompt(harness: "codex", allowsOther: false, multi: true))
        #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Glass", "Glass"]]]],
                                 question: codexMulti) == nil)
    }

    @Test func annotationsUseCurrentNativeRawPreviewsAndNotesBounds() throws {
        let question = try Self.fixture(Self.prompt(preview: "  <b>preview</b>  "))
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
        // acpmux reads annotations only for Claude Code's AskUserQuestion and drops any others.
        let codex = try Self.fixture(Self.prompt(harness: "codex"))
        #expect(try Self.failure(["optionId": "yes", "answers": ["q": ["answers": ["Glass"]]],
                                 "annotations": ["Choose?": ["notes": "x"]]], question: codex) == nil)
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
        let question = try Self.fixture(prompt)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>preview</b>"]]], question: question) == .annotations)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>native</b>"]]], question: question) == nil)
    }

    @Test func changedRequestWithEqualKeysRejectsOldChoiceAndPreview() throws {
        let first = try Self.fixture(Self.prompt(allowsOther: false, preview: "<b>old</b>"))
        let oldBody: [String: Any] = ["optionId": "yes", "answers": ["Choose?": "Glass"],
                                     "annotations": ["Choose?": ["preview": "<b>old</b>"]]]
        #expect(try Self.failure(oldBody, question: first) == nil)
        let next = try Self.fixture(Self.prompt(allowsOther: false, label: "New", preview: "<b>new</b>"))
        #expect(try Self.failure(oldBody, question: next) == .answers)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "New"],
                                 "annotations": ["Choose?": ["preview": "<b>old</b>"]]], question: next) == .annotations)
    }

    @Test func theFirstAllowOnceOptionAnswersAsTheQuestionCardSendsIt() throws {
        var request = try #require(Self.prompt()["request"] as? [String: Any])
        request["options"] = [["optionId": "yes", "kind": "allow_once"], ["optionId": "also", "kind": "allow_once"],
                              ["optionId": "no", "kind": "reject_once"], 7]
        let question = try Self.fixture(["request": request])
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]], question: question) == nil)
        #expect(try Self.failure(["optionId": "also", "answers": ["Choose?": "Other"]], question: question) == .option)
        // An option without a string id is skipped, as the card skips it.
        request["options"] = [["optionId": 7, "kind": "allow_once"], ["optionId": "yes", "kind": "allow_once"]]
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]],
                                 question: try Self.fixture(["request": request])) == nil)
        // A blank id is skipped as the card skips it.
        request["options"] = [["optionId": "  ", "kind": "allow_once"], ["optionId": "yes", "kind": "allow_once"]]
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]],
                                 question: try Self.fixture(["request": request])) == nil)
        // acpmux takes the first option with the id when it is of an allow kind.
        request["options"] = [["optionId": "yes", "kind": "allow_always"], ["optionId": "yes", "kind": "allow_once"]]
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]],
                                 question: try Self.fixture(["request": request])) == nil)
        // acpmux reads the first option with the id: a reject_once of the same id refuses it there.
        request["options"] = [["optionId": "yes", "kind": "reject_once"], ["optionId": "yes", "kind": "allow_once"]]
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]],
                                 question: try Self.fixture(["request": request])) == .option)
    }

    @Test func malformedNativeQuestionEntriesAreSkippedNotTrusted() throws {
        var request = try #require(Self.prompt()["request"] as? [String: Any])
        var tool = try #require(request["toolCall"] as? [String: Any])
        // A stray entry beside the real question, and one beside its option: acpmux skips both.
        tool["rawInput"] = ["questions": [["question": "Choose?",
                                           "options": [["label": "Glass", "preview": "<b>preview</b>"], 7]], 7]]
        request["toolCall"] = tool
        let question = try Self.fixture(["request": request])
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>preview</b>"]]], question: question) == nil)
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Glass"],
                                 "annotations": ["Choose?": ["preview": "<b>forged</b>"]]], question: question) == .annotations)
    }

    @Test func digestMustMatchTheImmutableRequest() throws {
        let native = try Self.fixture()
        let changed = AgentPaneQuestionReply.Input(sessionId: native.sessionId, permissionId: native.permissionId,
            requestJSON: native.requestJSON, requestDigest: String(repeating: "0", count: 64))
        #expect(try Self.failure(["optionId": "yes", "answers": ["Choose?": "Other"]],
                                question: changed) == .question)
    }

    @Test(arguments: [
        #"{"optionId":"yes","optionId":"no","answers":{"Choose?":"Other"}}"#,
        #"{"optionId":"yes","answers":{"Choose?":"first","Choose?":"second"}}"#,
        #"{"optionId":"yes","answers":{"Choose?":"Other"},"annotations":null}"#,
        #"["yes"]"#, #"{"optionId":"yes","answers":"Other"}"#,
        #"{"optionId":"yes","answers":{"Choose?":"Other"}}"# + " trailing"
    ])
    func malformedAndAmbiguousJSONIsRefused(text: String) throws {
        let question = try Self.fixture()
        #expect(throws: AgentPaneQuestionReply.Failure.self) {
            try AgentPaneQuestionReply(input: question, replyJSON: text)
        }
    }
}
