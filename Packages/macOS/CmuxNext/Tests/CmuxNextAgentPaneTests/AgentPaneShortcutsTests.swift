import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneShortcutsTests {
    /// The page reads the bindings the user has, not the catalog defaults.
    @Test func readsTheEffectiveBindings() {
        let registry = ActionRegistry.standard()
        #expect(AgentPaneShortcuts.read(registry).labels == [
            "agentPane.searchChats": "⌘K", "palette.newAgentChat": "⇧⌘I", "palette.toggleDictation": "⌃⌘V",
        ])
        registry.setShortcutOverride(Shortcut("p", modifiers: [.command, .option]), for: "agentPane.searchChats")
        registry.setShortcutOverride(nil, for: "palette.toggleDictation")
        #expect(AgentPaneShortcuts.read(registry).labels == ["agentPane.searchChats": "⌥⌘P", "palette.newAgentChat": "⇧⌘I"])
    }

    @Test func handsTheLabelsToThePageBridge() throws {
        let script = try #require(AgentPaneShortcuts(labels: ["agentPane.searchChats": "⌘K"]).script())
        #expect(script == #"window.cmuxAcpmuxBridge?.applyShortcuts?.({"agentPane.searchChats":"⌘K"});"#)
    }

    /// A change pushes the labels; an unchanged value pushes nothing.
    @Test func aChangePushesTheLabels() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost())))
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.shortcuts = AgentPaneShortcuts(labels: ["agentPane.searchChats": "⌘K"])
        view.shortcuts = AgentPaneShortcuts(labels: ["agentPane.searchChats": "⌘K"])
        #expect(scripts.filter { $0.contains("applyShortcuts") }.count == 1)
    }
}
