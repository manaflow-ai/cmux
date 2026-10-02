import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
@Suite struct AgentPaneActionTests {
    @Test func newAgentChatIsBoundAndRunsWithItsTarget() {
        let registry = ActionRegistry.standard()
        var opened: [ActionTargetRef?] = []
        #expect(registry.bindAgentPane { opened.append($0.target) })
        #expect(registry.isBound(.newAgentChat))
        let pane = ActionTargetRef(kind: .pane, id: "pane-1")
        #expect(registry.perform(.newAgentChat, invocation: ActionInvocation(target: pane)))
        #expect(opened == [pane])
    }

    /// Every entrypoint comes from the descriptor: palette, File menu, the
    /// new-tab menu, and the CLI verb.
    @Test func theDescriptorReachesEveryEntrypoint() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == .newAgentChat })
        #expect(descriptor.cliName == "agent new-chat")
        #expect(descriptor.mainMenu == .file)
        #expect(descriptor.targets == [.pane])
        #expect(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .newTab)).contains(.newAgentChat))
    }

    @Test func showACPInspectorIsBoundAndRunsWithItsTarget() throws {
        let registry = ActionRegistry.standard()
        var toggled: [ActionTargetRef?] = []
        #expect(registry.bindAgentPaneInspector { toggled.append($0.target) })
        #expect(registry.isBound(.toggleAcpInspector))
        let pane = ActionTargetRef(kind: .pane, id: "pane-1")
        #expect(registry.perform(.toggleAcpInspector, invocation: ActionInvocation(target: pane)))
        #expect(toggled == [pane])
        let descriptor = try #require(ActionCatalog.all.first { $0.id == .toggleAcpInspector })
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.cliName == "agent toggle-acp-inspector")
        #expect(descriptor.targets == [.pane])
        #expect(descriptor.defaultShortcut == nil)
    }

    /// The action and `debug.agent_pane inspector` call the page's bridge,
    /// which ignores the call until the page has loaded it.
    @Test func togglingTheInspectorCallsThePageBridge() throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-inspector-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.toggleInspector()
        view.toggleInspector(open: true)
        view.toggleInspector(open: false)
        #expect(scripts == [
            "window.cmuxAcpmuxBridge?.toggleInspector?.();",
            "window.cmuxAcpmuxBridge?.toggleInspector?.(true);",
            "window.cmuxAcpmuxBridge?.toggleInspector?.(false);"
        ])
    }
}
