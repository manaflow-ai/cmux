import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-nn3e.1 (nxdog80 preflight): opening a chat whose folder was deleted showed a bare macOS Open
/// panel with no explanation. The chat now opens in its pane; one line above the composer says the
/// folder is gone and offers Choose Folder. The pick re-opens the chat there: a resumable chat is
/// adopted in this pane at once.
@MainActor
@Suite struct AgentPaneMissingFolderTests {
    static let needed = AgentPaneFolderNeeded(chat: "claude:abc", reason: "the chat's folder /old was deleted or moved; pick one")

    static func model(_ choose: @escaping @MainActor (String) async -> AgentPaneChatFolderResult) -> AgentPaneModel {
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: AgentPaneSeedSource(AgentPaneSeed(folderNeeded: needed)))
        model.onChooseChatFolder = choose
        return model
    }

    static func value(_ reply: [String: Any]) -> [String: Any]? { reply["value"] as? [String: Any] }

    @Test func theRequestDecodesFromBothBridges() {
        #expect(AgentPaneRequest(body: ["method": "chat.folder.choose", "params": [String: Any]()]) == .chooseChatFolder)
        #expect(AgentPageOps.method(for: "cmux.agent.chat.folder.choose") == "chat.folder.choose")
    }

    @Test func theHandshakeSaysTheFolderIsGoneUntilItIsResolved() async throws {
        let model = Self.model { _ in .cancelled }
        let first = try #require(Self.value(await model.respond(to: .ready)))
        #expect((first["folderNeeded"] as? [String: Any])?["reason"] as? String == Self.needed.reason)
        let reload = try #require(Self.value(await model.respond(to: .ready)))
        #expect((reload["folderNeeded"] as? [String: Any])?["reason"] as? String == Self.needed.reason)
    }

    @Test func choosingNeedsAGesture() async {
        var asked = 0
        let model = Self.model { _ in asked += 1; return .cancelled }
        _ = await model.respond(to: .ready)
        let reply = await model.respond(to: .chooseChatFolder)
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(asked == 0)
    }

    @Test func aPickedFolderResumesTheChatHere() async throws {
        var chats: [String] = []
        let adopt = AgentPaneAdopt(harness: "claude", agentSessionId: "abc")
        let model = Self.model { chat in chats.append(chat); return .adopt(adopt, cwd: "/new") }
        _ = await model.respond(to: .ready)
        model.transport.gestures.record()
        let value = try #require(Self.value(await model.respond(to: .chooseChatFolder)))
        #expect(chats == [Self.needed.chat])
        #expect(value["adopt"] as? [String: String] == ["harness": "claude", "agentSessionId": "abc"])
        #expect(value["cwd"] as? String == "/new")
        let after = try #require(Self.value(await model.respond(to: .ready)))
        #expect(after["folderNeeded"] == nil)
    }

    @Test func aCancelledOrStillMissingPickKeepsTheLine() async throws {
        var answers: [AgentPaneChatFolderResult] = [.cancelled, .needsFolder("cwd /tmp/x is not a folder")]
        let model = Self.model { _ in answers.removeFirst() }
        _ = await model.respond(to: .ready)
        model.transport.gestures.record()
        #expect(Self.value(await model.respond(to: .chooseChatFolder))?.isEmpty ?? true)
        model.transport.gestures.record()
        let still = try #require(Self.value(await model.respond(to: .chooseChatFolder)))
        #expect(still["reason"] as? String == "cwd /tmp/x is not a folder")
        let handshake = try #require(Self.value(await model.respond(to: .ready)))
        #expect((handshake["folderNeeded"] as? [String: Any])?["reason"] as? String == "cwd /tmp/x is not a folder")
    }
}
