import Foundation
import Testing

@testable import CmuxNextAgentPane

/// `chat.placement`: the Auto / pinned mark the page keeps as a chat's session tag (design/auto-chat-placement.md).
@Suite struct AgentPaneChatPlacementTests {
    @Test func decodesOnlyASessionAndAutoOrPinned() {
        #expect(AgentPaneRequest(body: ["method": "chat.placement", "params": ["sessionId": "s1", "placement": "auto"]])
            == .chatPlacement(.init(params: ["sessionId": "s1", "placement": "auto"])!))
        #expect(AgentPaneChatPlacement(params: ["sessionId": "s1", "placement": "pinned"])?.placement == "pinned")
        for params: [String: Any] in [
            ["sessionId": "s1", "placement": "Auto"],
            ["sessionId": "s1", "placement": "local"],
            ["sessionId": "", "placement": "auto"],
            ["sessionId": String(repeating: "x", count: 257), "placement": "auto"],
            ["sessionId": "s1"],
            ["sessionId": "s1", "placement": "auto", "tag": "archived"],
            ["sessionId": 7, "placement": "auto"],
        ] {
            #expect(AgentPaneRequest(body: ["method": "chat.placement", "params": params]) == .unsupported("chat.placement"))
        }
    }

    /// Pinning only stops Auto moving a chat, so any listed chat may be pinned; Auto lets it move,
    /// so only the pane's own chat (or a new chat's first, before the pane learns its session).
    @Test func autoOnlyForThePanesOwnChat() throws {
        let auto = try #require(AgentPaneChatPlacement(params: ["sessionId": "s1", "placement": "auto"]))
        let pinned = try #require(AgentPaneChatPlacement(params: ["sessionId": "s1", "placement": "pinned"]))
        #expect(auto.allowed(paneSession: "s1"))
        #expect(auto.allowed(paneSession: nil))
        #expect(!auto.allowed(paneSession: "other"))
        #expect(pinned.allowed(paneSession: "other"))
    }

    @Test func aCloudStartKeepsOnlyAKnownPlacement() {
        let base: [String: Any] = ["task": "hi", "key": UUID().uuidString]
        #expect(AgentPaneCloudStart(params: base.merging(["placement": "auto"]) { $1 })?.placement == "auto")
        #expect(AgentPaneCloudStart(params: base)?.placement == nil)
        #expect(AgentPaneCloudStart(params: base.merging(["placement": "elsewhere"]) { $1 })?.placement == nil)
    }

    @Test func thePageMayCallIt() {
        #expect(AgentPageOps.all.contains("cmux.agent.chat.placement"))
    }
}
