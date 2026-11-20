import CmuxNextActions
import CmuxNextAgentPane
import Foundation
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The header's inline rename form (the elevation-ladder experiment): the page sends
/// `pane.action {id: "renameTab", name}` and the App runs Rename Tab with that name on the chat's
/// tab, with no prompt. A `renameTab` without a name stays the plain header action (the prompt).
@MainActor
struct HeaderInlineRenameTests {
    static func message(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "pane.action", "params": params])
    }

    @Test func aNameDecodesAsTheInlineRename() {
        guard case .renameTab(let name) = Self.message(["id": "renameTab", "name": "Release notes"]) else {
            Issue.record("pane.action renameTab with a name did not decode as the inline rename")
            return
        }
        #expect(name == "Release notes")
    }

    @Test func withoutANameItIsTheHeaderActionThatPrompts() {
        guard case .paneAction("renameTab", _, _) = Self.message(["id": "renameTab"]) else {
            Issue.record("pane.action renameTab without a name is no longer the header action")
            return
        }
    }

    @Test func anOverlongNameIsRefused() {
        guard case .unsupported = Self.message(["id": "renameTab", "name": String(repeating: "a", count: 513)]) else {
            Issue.record("a 513-character name was taken")
            return
        }
    }

    /// The hook the App installs runs Rename Tab on the chat's tab with the name as its argument.
    @Test func theNameReachesRenameTabOnTheChatsTab() {
        let registry = ActionRegistry()
        var ran: ActionInvocation?
        registry.register(Action(id: "renameTab", title: "renameTab", invoke: { ran = $0 }, handler: {}))
        let actions = AgentChatTabActions(tab: { "surface:1" }, registry: { registry })
        actions.run("renameTab", cwd: nil, extra: ["name": .string("Release notes")])
        #expect(ran?.target?.id == "surface:1")
        #expect(ran?["name"]?.stringValue == "Release notes")
    }
}
