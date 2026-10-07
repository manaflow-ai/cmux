import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneShortcutsTests {
    /// The page reads the bindings the user has, not the catalog defaults.
    @Test func readsTheEffectiveBindings() {
        let registry = ActionRegistry.standard()
        let header = AgentPaneModel.headerActions
        let labels = { AgentPaneShortcuts.read(registry).labels.filter { !header.contains($0.key) } }
        #expect(labels() == [
            "palette.newAgentChat": "⌘I", "palette.toggleDictation": "⌃⌘V",
            "agentPane.permission.allowOnce": "⌥⌘1", "agentPane.permission.allowChat": "⌥⌘2",
            "agentPane.permission.deny": "⌥⌘3", "agentPane.permission.expand": "⌥⌘4",
        ])
        registry.setShortcutOverride(Shortcut("p", modifiers: [.command, .option]), for: "palette.newAgentChat")
        registry.setShortcutOverride(nil, for: "palette.toggleDictation")
        #expect(labels() == [
            "palette.newAgentChat": "⌥⌘P",
            "agentPane.permission.allowOnce": "⌥⌘1", "agentPane.permission.allowChat": "⌥⌘2",
            "agentPane.permission.deny": "⌥⌘3", "agentPane.permission.expand": "⌥⌘4",
        ])
        // Copy chat link shows Copy Tab Link's key once the user binds one.
        registry.setShortcutOverride(Shortcut("l", modifiers: [.command, .option]), for: "palette.copySurfaceLink")
        #expect(AgentPaneShortcuts.read(registry).labels["palette.copySurfaceLink"] == "⌥⌘L")
    }

    /// The chat header's tools and menu rows show the catalog's keys.
    @Test func readsTheHeaderActionBindings() {
        let labels = AgentPaneShortcuts.read(ActionRegistry.standard()).labels
        #expect(labels["splitRight"] == "⌘D")
        #expect(labels["splitBrowserRight"] == "⌥⌘D")
        #expect(labels["renameTab"] == "⌘R")
        #expect(labels["closeTab"] == "⌘W")
        #expect(labels["moveSurfaceToPaneRight"]?.hasSuffix("→") == true)
        for id in AgentPaneModel.headerActions {
            #expect(AgentPaneShortcuts.actions.contains(ActionID(rawValue: id)), "\(id)")
        }
    }

    @Test func handsTheLabelsToThePageBridge() throws {
        let script = try #require(AgentPaneShortcuts(labels: ["palette.newAgentChat": "⌘I"]).script())
        #expect(script == #"window.cmuxAcpmuxBridge?.applyShortcuts?.({"palette.newAgentChat":"⌘I"});"#)
    }

    /// A change pushes the labels; an unchanged value pushes nothing.
    @Test func aChangePushesTheLabels() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost())))
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.shortcuts = AgentPaneShortcuts(labels: ["palette.newAgentChat": "⌘I"])
        view.shortcuts = AgentPaneShortcuts(labels: ["palette.newAgentChat": "⌘I"])
        #expect(scripts.filter { $0.contains("applyShortcuts") }.count == 1)
    }
}
