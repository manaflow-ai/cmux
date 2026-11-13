import AppKit
@testable import CmuxNextAgentPane
import Testing

@Suite(.serialized)
@MainActor
struct AgentPanePromptAgainMenuTests {
    private static let resend: [String: Any] = [
        "sessionId": "chat-1", "rowId": "prompt-1", "label": "Send prompt again",
        "modelsLabel": "Retry with another model", "moreModelsLabel": "More models",
        "currentModel": "model-b",
        "latestModels": [["id": "model-a", "name": "Model A"], ["id": "model-b", "name": "Model B"]],
        "moreModels": [["id": "model-c", "name": "Model C"]],
    ]

    @Test func parsesSessionBoundResendOnAReply() throws {
        let target = try #require(AgentPaneMessageTarget(report: ["sessionId": "chat-1", "text": "Done", "markdown": "Done", "sendPromptAgain": Self.resend]))
        #expect(target.text == "Done")
        #expect(target.sendPromptAgain?.rowId == "prompt-1")
        #expect(target.sendPromptAgain?.currentModel == "model-b")
    }

    @Test func acceptsActionOnlyTargetForAReplyEndingOnTools() throws {
        let target = try #require(AgentPaneMessageTarget(report: ["sessionId": "chat-1", "sendPromptAgain": Self.resend]))
        #expect(target.text.isEmpty)
        #expect(target.sendPromptAgain?.rowId == "prompt-1")
        let menu = AgentPaneMenuLookTests.menu(target: target)
        #expect(menu.items.contains { $0.title == "Send prompt again" })
    }

    @Test func rejectsMissingOrMismatchedResendOwnership() {
        #expect(AgentPaneMessageTarget(report: ["sessionId": "other", "sendPromptAgain": Self.resend]) == nil)
        #expect(AgentPaneMessageTarget(report: ["sendPromptAgain": Self.resend]) == nil)
        var invalid = Self.resend
        invalid["rowId"] = ""
        #expect(AgentPaneMessageTarget(report: ["sessionId": "chat-1", "sendPromptAgain": invalid]) == nil)
    }

    @Test func sendsOriginalTargetAndSelectedModelThroughPageAction() throws {
        _ = NSApplication.shared
        let target = try #require(AgentPaneMessageTarget(report: ["sessionId": "chat-1", "text": "Done", "markdown": "Done", "sendPromptAgain": Self.resend]))
        var calls: [(String, [String: String])] = []
        let menu = AgentPaneMenuLookTests.menu(target: target, page: { calls.append(($0, $1)) })
        let send = try #require(menu.items.first { $0.title == "Send prompt again" })
        let models = try #require(menu.items.first { $0.title == "Retry with another model" }?.submenu)
        let picked = try #require(models.items.first { $0.title == "Model B" })
        #expect(picked.state == .on)
        #expect(models.items.first { $0.title == "Model A" }?.state == .off)
        let more = try #require(models.items.first { $0.title == "More models" }?.submenu)
        let other = try #require(more.items.first)
        menu.performActionForItem(at: menu.index(of: send))
        more.performActionForItem(at: more.index(of: other))
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while calls.count < 2, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        #expect(calls.map(\.0) == ["chat.sendPromptAgain", "chat.sendPromptAgain"])
        #expect(calls.first?.1 == ["sessionId": "chat-1", "rowId": "prompt-1"])
        #expect(calls.last?.1 == ["sessionId": "chat-1", "rowId": "prompt-1", "model": "model-c"])
    }

    @Test func selectionMenuDoesNotResendThePrompt() throws {
        let target = try #require(AgentPaneMessageTarget(report: [
            "sessionId": "chat-1", "text": "Done", "markdown": "Done", "sendPromptAgain": Self.resend,
        ]))
        let menu = AgentPaneMenuLookTests.menu(target: target, selection: "Done")
        #expect(!menu.items.contains { $0.title == "Send prompt again" })
    }
}
