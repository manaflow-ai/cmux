import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `feed.list`, `feed.permission.reply` and `feed.question.reply` over the
/// control socket (`cmux agents dialog list|answer`, `agents wait --until
/// dialog`, `agents events`): the pending acpmux prompts of every session,
/// a deny for a permission (never an allow), and a question's answer in the
/// asking harness's shape.
@MainActor @Suite(.serialized) struct AgentDialogControlTests {
    /// A fake acpmux connection: two sessions, one with a tool permission and
    /// one with a Claude Code question. It records what it was sent.
    final class FakeLine: AgentDialogLine {
        var isPerson = true
        var sent: [(method: String, params: [String: Any])] = []
        var pending: [String: [[String: Any]]] = [
            "s-tool": [[
                "permissionId": "perm-tool",
                "request": [
                    "toolCall": ["title": "Run rm -rf build", "kind": "execute", "rawInput": ["command": "rm -rf build"]],
                    "options": [["optionId": "yes", "kind": "allow_once", "name": "Allow"],
                                ["optionId": "no", "kind": "reject_once", "name": "Deny"]],
                ] as [String: Any],
            ]],
            "s-ask": [[
                "permissionId": "perm-ask",
                "request": [
                    "toolCall": ["title": "AskUserQuestion", "_meta": ["claude": ["tool": "AskUserQuestion"]],
                                 "rawInput": ["questions": [["question": "Which database?", "header": "DB",
                                                              "options": [["label": "Postgres"], ["label": "SQLite"]]]]]],
                    "options": [["optionId": "ok", "kind": "allow_once", "name": "Answer"],
                                ["optionId": "skip", "kind": "reject_once", "name": "Skip"]],
                ] as [String: Any],
            ]],
        ]

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            sent.append((method, params))
            switch method {
            case "_acpmux/sessions":
                return ["sessions": [
                    ["sessionId": "s-idle", "name": "idle", "pendingPermissions": 0],
                    ["sessionId": "s-tool", "name": "builder", "pendingPermissions": 1],
                    ["sessionId": "s-tool", "name": "builder", "pendingPermissions": 1],
                    ["sessionId": "offline", "name": "peer", "peer": "gcp", "pendingPermissions": 1],
                    ["sessionId": "s-ask", "name": "asker", "pendingPermissions": 1],
                ]]
            case "_acpmux/info":
                return ["pending": pending[params["sessionId"] as? String ?? ""] ?? []]
            case "_acpmux/permission_respond":
                return [:]
            default:
                return nil
            }
        }

        func close() {}

        var responds: [[String: Any]] { sent.filter { $0.method == "_acpmux/permission_respond" }.map(\.params) }
    }

    private func router(_ desk: AgentDialogDesk) -> ControlRouter {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(FeedControl.methods(services: services, dialogs: desk))
        return router
    }

    private func desk(_ line: FakeLine?) -> AgentDialogDesk {
        AgentDialogDesk(open: { line }, tab: { session in session == "s-ask" ? "tab_ask" : nil })
    }

    private func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    @Test func listShowsThePendingPromptsOfEverySession() async throws {
        let line = FakeLine()
        let reply = try await call(router(desk(line)), "feed.list", ["pending_only": true]).get()
        let items = try #require(reply["items"]?.arrayValue)
        #expect(items.count == 2)
        let tool = try #require(items.first { $0["request_id"]?.stringValue == "perm-tool" })
        #expect(tool["id"]?.stringValue == "perm-tool")
        #expect(tool["kind"]?.stringValue == "permissionRequest")
        #expect(tool["status"]?.stringValue == "pending")
        #expect(tool["session_id"]?.stringValue == "s-tool")
        #expect(tool["title"]?.stringValue == "Run rm -rf build")
        #expect(tool["command"]?.stringValue == "rm -rf build")
        let ask = try #require(items.first { $0["request_id"]?.stringValue == "perm-ask" })
        #expect(ask["kind"]?.stringValue == "question")
        #expect(ask["tab_id"]?.stringValue == "tab_ask")
        let question = try #require(ask["questions"]?.arrayValue?.first)
        #expect(question["prompt"]?.stringValue == "Which database?")
        #expect(question["options"]?.arrayValue?.compactMap { $0["label"]?.stringValue } == ["Postgres", "SQLite"])
        let list = try #require(line.sent.first { $0.method == "_acpmux/sessions" })
        #expect(list.params["status"] == nil)
        #expect(list.params["limit"] as? Int == 64)
        #expect(line.sent.filter { $0.method == "_acpmux/info" }.compactMap { $0.params["sessionId"] as? String } == ["s-tool", "offline", "s-ask"])
    }

    @Test func listWithNoAcpmuxIsEmpty() async throws {
        let reply = try await call(router(desk(nil)), "feed.list", [:]).get()
        #expect(reply["items"]?.arrayValue?.isEmpty == true)
    }

    @Test func aPermissionIsDeniedWithItsRejectOption() async throws {
        let line = FakeLine()
        _ = try await call(router(desk(line)), "feed.permission.reply", ["request_id": "perm-tool", "mode": "deny"]).get()
        let respond = try #require(line.responds.first)
        #expect(respond["sessionId"] as? String == "s-tool")
        #expect(respond["permissionId"] as? String == "perm-tool")
        #expect(respond["optionId"] as? String == "no")
    }

    @Test(arguments: ["allow", "always", "bypassPermissions", "acceptEdits"])
    func aPermissionIsNeverAllowedFromTheSocket(mode: String) async throws {
        let line = FakeLine()
        let result = await call(router(desk(line)), "feed.permission.reply", ["request_id": "perm-tool", "mode": .string(mode)])
        guard case .failure(let error) = result else { Issue.record("\(mode) was accepted"); return }
        #expect(error.code == "person_required")
        #expect(line.responds.isEmpty)
    }

    @Test func aQuestionIsAnsweredInTheHarnessShape() async throws {
        let line = FakeLine()
        _ = try await call(router(desk(line)), "feed.question.reply", ["request_id": "perm-ask", "selections": ["sqlite"]]).get()
        let respond = try #require(line.responds.first)
        #expect(respond["sessionId"] as? String == "s-ask")
        #expect(respond["optionId"] as? String == "ok")
        #expect((respond["answers"] as? [String: Any])?["Which database?"] as? String == "SQLite")
    }

    @Test func aQuestionAnswerByItemKeyAndOtherText() async throws {
        let line = FakeLine()
        _ = try await call(router(desk(line)), "feed.question.reply", ["request_id": "perm-ask", "selections": ["DB=MySQL"]]).get()
        #expect((line.responds.first?["answers"] as? [String: Any])?["Which database?"] as? String == "MySQL")
    }

    @Test func aToolPermissionTakesNoQuestionAnswer() async {
        let line = FakeLine()
        let result = await call(router(desk(line)), "feed.question.reply", ["request_id": "perm-tool", "selections": ["Allow"]])
        guard case .failure(let error) = result else { Issue.record("a tool permission took an answer"); return }
        #expect(error.code == "invalid_params")
        #expect(line.responds.isEmpty)
    }

    @Test func anUnknownRequestIsNotFound() async {
        let result = await call(router(desk(FakeLine())), "feed.permission.reply", ["request_id": "gone", "mode": "deny"])
        guard case .failure(let error) = result else { Issue.record("an unknown request was answered"); return }
        #expect(error.code == "not_found")
    }

    @Test func anAnsweredDialogIsListedWithAll() async throws {
        let line = FakeLine()
        let router = router(desk(line))
        _ = try await call(router, "feed.permission.reply", ["request_id": "perm-tool", "mode": "deny"]).get()
        line.pending["s-tool"] = []
        let pending = try await call(router, "feed.list", ["pending_only": true]).get()
        #expect(pending["items"]?.arrayValue?.compactMap { $0["request_id"]?.stringValue } == ["perm-ask"])
        let all = try await call(router, "feed.list", ["pending_only": false]).get()
        let denied = try #require(all["items"]?.arrayValue?.first { $0["request_id"]?.stringValue == "perm-tool" })
        #expect(denied["status"]?.stringValue == "denied")
    }
}
