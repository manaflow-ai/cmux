@testable import CmuxNextApp
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

    @Test func aQuestionIsNeverPostedAsAPermission() throws {
        let params = try Self.params(Self.question)
        #expect(params["kind"] as? String != "approve")
        #expect(params["type"] as? String == "notice")
        #expect(params["prompt"] == nil)
        let title = try #require(params["title"] as? String)
        #expect(!title.hasPrefix("Allow"))
        #expect(title.contains("Claude Code"))
        #expect(title.contains("Which database should I use?"))
        // It still opens the chat that asks, and reaches the phone as fast as a permission did.
        #expect((params["context"] as? [String: Any])?["acp_session"] as? String == "sess-1")
        #expect(params["priority"] as? String == "high")
        #expect(params["expires_in_ms"] as? Int == 86_400_000)
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
