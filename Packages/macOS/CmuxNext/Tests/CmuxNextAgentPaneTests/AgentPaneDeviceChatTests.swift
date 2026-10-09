import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab page's chat cards read the device chat index the sidebar's All chats shows
/// (chief finding 2026-10-09: "No chats" beside 375 chats in the sidebar): the host pushes the
/// newest chats (`deviceChats`) and a card opens through `cmux.agent.chats.open`.
@MainActor
@Suite struct AgentPaneDeviceChatTests {
    @Test func thePushCarriesKeyHarnessTitleAndMilliseconds() {
        let chats = (0..<40).map {
            AgentPaneDeviceChat(key: "codex:\($0)", harness: "codex", title: $0 == 0 ? nil : "Chat \($0)",
                                updatedAt: Date(timeIntervalSince1970: 1_000 + Double($0)))
        }
        let event = AgentPageEvent.deviceChats(chats)
        #expect(event.kind == "deviceChats")
        guard case .array(let items) = event.value else { Issue.record("not an array"); return }
        #expect(items.count == AgentPaneDeviceChat.maximumPushed)
        #expect(items[0] == ["key": "codex:0", "harness": "codex", "updatedAt": .number(1_000_000)])
        #expect(items[1]["title"] == "Chat 1")
    }

    @Test func aCardOpensThroughTheHostsOpenChat() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var opened: [String] = []
        model.onOpenChat = { opened.append($0) }
        let provider = AgentPageProvider { _ in model }
        let router = PageRouter(descriptor: .agent, routes: [PageRoute(prefix: "cmux.agent.", provider: provider)])
        let reply = await router.handle(["t": "call", "id": 1, "op": "cmux.agent.chats.open", "params": ["key": "codex:01999a2b"]])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(opened == ["codex:01999a2b"])
        let bad = await router.handle(["t": "call", "id": 2, "op": "cmux.agent.chats.open", "params": ["key": "nocolon"]])
        #expect(bad["t"]?.stringValue != "ok")
        #expect(opened == ["codex:01999a2b"])
    }
}
