@testable import CmuxNextApp
import CmuxNextFeed
import Foundation
import Testing

/// A question an agent asks (AskUserQuestion, a Codex user-input request, the folder-trust card)
/// reaches acpmux as a `session/request_permission` marked `toolCall._meta.acpmux.question`. The
/// feed bridge never posts it as a permission: no `approve` item, no "Allow …?" title. A plain tool
/// permission still posts as one.
struct AcpmuxFeedBridgeQuestionTests {
    static var options: [[String: Any]] {
        [["optionId": "allow", "kind": "allow_once", "name": "Allow"],
         ["optionId": "reject", "kind": "reject_once", "name": "Reject"]]
    }

    /// What acpmux sends for Claude Code's AskUserQuestion once the hub normalized it.
    static var question: [String: Any] {
        let item: [String: Any] = [
            "id": "q0", "header": "Database", "prompt": "Which database should I use?",
            "options": [["id": "o0", "label": "Postgres"], ["id": "o1", "label": "SQLite"]],
            "multiSelect": false, "allowsOther": true,
        ]
        let normalized: [String: Any] = ["harness": "claude", "agent": "Claude Code", "items": [item]]
        let asked: [String: Any] = [
            "question": "Which database should I use?", "header": "Database",
            "options": [["label": "Postgres"], ["label": "SQLite"]],
        ]
        let call: [String: Any] = [
            "toolCallId": "call-1", "title": "AskUserQuestion", "kind": "other",
            "rawInput": ["questions": [asked]],
            "_meta": ["claude": ["tool": "AskUserQuestion"], "acpmux": ["question": normalized]],
        ]
        return ["sessionId": "sess-1", "toolCall": call, "options": options]
    }

    static var bash: [String: Any] {
        let call: [String: Any] = [
            "toolCallId": "call-2", "title": "Run tests", "kind": "execute",
            "rawInput": ["command": "swift test --filter Login"],
        ]
        return ["sessionId": "sess-1", "toolCall": call, "options": options]
    }

    static func params(_ request: [String: Any]) throws -> [String: Any] {
        let body = AcpmuxPermissionFeedBridge.postBody(session: "sess-1", permission: "perm-1", request: request, host: "inst_mac")
        #expect(body["op"] as? String == "feed.post")
        return try #require(body["params"] as? [String: Any])
    }

    /// The question posts as a `choice` the person answers in the feed, with every option shown
    /// and the agent named, never as a permission and never as a bare "asks:" notice.
    @Test func aQuestionPostsAsAnAnswerableChoice() throws {
        let body = AcpmuxPermissionFeedBridge.postBody(session: "sess-1", permission: "perm-1", request: Self.question,
                                                       host: "inst_mac", agent: "claude")
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["kind"] as? String == "choice")
        #expect(params["type"] as? String == "request")
        let title = try #require(params["title"] as? String)
        #expect(!title.hasPrefix("Allow"))
        #expect(title == "Which database should I use?")
        #expect((params["poster"] as? [String: Any])?["label"] as? String == "claude")
        let questions = try #require((params["prompt"] as? [String: Any])?["questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions[0]["id"] as? String == "q0")
        #expect(questions[0]["header"] as? String == "Database")
        #expect((questions[0]["options"] as? [[String: Any]])?.map { $0["label"] as? String } == ["Postgres", "SQLite"])
        #expect((questions[0]["options"] as? [[String: Any]])?.map { $0["id"] as? String } == ["o0", "o1"])
        #expect(questions[0]["allow_other"] as? Bool == true)
        let text = try #require(params["body"] as? String)
        #expect(text.contains("Which database should I use?") && text.contains("- Postgres") && text.contains("- SQLite"))
        // It still opens the chat that asks, and reaches the phone as fast as a permission did.
        #expect((params["context"] as? [String: Any])?["acp_session"] as? String == "sess-1")
        #expect(params["priority"] as? String == "high")
        #expect(params["expires_in_ms"] as? Int == 86_400_000)
    }

    /// A feed answer maps back onto the question's own option ids, as acpmux's reply.
    @Test func aChoiceAnswerAnswersTheQuestion() throws {
        func params(_ answers: [String: FeedChoiceSelection]) -> [String: Any]? {
            AcpmuxPermissionFeedBridge.respondParams(request: Self.question, session: "sess-1", permission: "perm-1", answers: answers)
        }
        let reply = try #require(params(["q0": FeedChoiceSelection(selected: ["o1"])]))
        #expect(reply["permissionId"] as? String == "perm-1")
        #expect(reply["sessionId"] as? String == "sess-1")
        let picked = try JSONSerialization.data(withJSONObject: reply)
        #expect(String(data: picked, encoding: .utf8)?.contains("SQLite") == true)
        // An option or question the posted choice never had answers nothing.
        #expect(params(["q0": FeedChoiceSelection(selected: ["o7"])]) == nil)
        #expect(params(["q3": FeedChoiceSelection(selected: ["o0"])]) == nil)
    }

    /// From the owner, only another install answers a question (as a deny): never a session answer
    /// (a browser, or a process holding the person's session), never this Mac's own install.
    @Test func aSessionAnswerNeverAnswersAQuestion() {
        func refusal(_ by: String) -> AcpmuxPermissionFeedBridge.Refusal? {
            if case .failure(let refusal) = AcpmuxPermissionFeedBridge.admits(by: by, ownInstall: "inst_mac") { return refusal }
            return nil
        }
        #expect(refusal("session:usr_1") == .sessionAnswer)
        #expect(refusal("inst_phone") == nil)
        // This Mac's own install never answers through the owner: the person answers here
        // through the bridge directly (`answeredHere`), as in the chat.
        #expect(refusal("inst_mac") == .ownInstall)
    }

    /// A question that does not fit a choice (one option) stays a notice naming the agent.
    @Test func aQuestionThatDoesNotFitAChoiceStaysANotice() throws {
        var request = Self.question
        var call = try #require(request["toolCall"] as? [String: Any])
        var meta = try #require(call["_meta"] as? [String: Any])
        var acpmux = try #require(meta["acpmux"] as? [String: Any])
        var normalized = try #require(acpmux["question"] as? [String: Any])
        normalized["items"] = [["id": "q0", "prompt": "Proceed?", "options": [["id": "o0", "label": "Yes"]],
                                "multiSelect": false, "allowsOther": false]]
        acpmux["question"] = normalized
        meta["acpmux"] = acpmux
        call["_meta"] = meta
        call["rawInput"] = ["questions": [["question": "Proceed?", "options": [["label": "Yes"]]]]]
        request["toolCall"] = call
        let params = try Self.params(request)
        #expect(params["type"] as? String == "notice")
        #expect((params["title"] as? String ?? "").contains("asks"))
    }

    @Test func aQuestionWithNoTextStillReadsAsAQuestion() throws {
        var request = Self.question
        var call = try #require(request["toolCall"] as? [String: Any])
        call["title"] = ""
        call["rawInput"] = [:] as [String: Any]
        call["_meta"] = ["acpmux": ["question": ["agent": "Codex", "items": [[String: Any]]()]]] as [String: Any]
        request["toolCall"] = call
        let title = try #require(try Self.params(request)["title"] as? String)
        #expect(title == "Codex asks a question")
    }

    @Test func anAskUserQuestionWithoutTheNormalizedQuestionIsStillAQuestion() throws {
        var request = Self.question
        var call = try #require(request["toolCall"] as? [String: Any])
        call["_meta"] = ["claude": ["tool": "AskUserQuestion"]] as [String: Any]
        request["toolCall"] = call
        let params = try Self.params(request)
        #expect(params["kind"] as? String != "approve")
        #expect(!(params["title"] as? String ?? "").hasPrefix("Allow"))
    }

    @Test func aToolPermissionStillPostsAnApproveItem() throws {
        let params = try Self.params(Self.bash)
        #expect(params["type"] as? String == "request")
        #expect(params["kind"] as? String == "approve")
        #expect(params["title"] as? String == "Allow Run tests?")
        let action = try #require((params["prompt"] as? [String: Any])?["action"] as? [String: Any])
        #expect(action["command"] as? String == "swift test --filter Login")
    }
}
