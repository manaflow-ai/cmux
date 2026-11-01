import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Inspect Element (#24707, the UI pointer inspector) is a Debug/Labs surface, so the tab bar's +
/// menu ships without it: the row shows only once Debug Settings' "UI pointer inspector" is on,
/// last in its own group.
@MainActor @Suite(.serialized) struct PointerInspectorMenuGateTests {
    /// The + menu's rows as the actions they run, "—" for a separator.
    private func newTabRows(inspector on: Bool?) -> [String] {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, on.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        let registry = ActionRegistry.standard()
        // The gate applies to a bound action, as AgentHandlers binds it first.
        registry.bind("agentPane.togglePointerInspector", invoke: { _ in })
        AgentHandlers.gatePointerInspectorMenuRows(in: registry)
        let menu = registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: "p"))
        return menu.items.map { $0.isSeparatorItem ? "—" : ActionRegistry.menuRun(of: $0)?.id.rawValue ?? $0.title }
    }

    @Test func theInspectorIsOffByDefault() {
        #expect(AgentPaneTunables.pointerInspector.defaultValue == false)
    }

    @Test func theNewTabMenuLeavesInspectElementOutByDefault() {
        for off in [newTabRows(inspector: nil), newTabRows(inspector: false)] {
            #expect(!off.contains("agentPane.togglePointerInspector"), "\(off)")
            #expect(off.first == "newSurface" && off.last != "—", "\(off)")
        }
    }

    /// On, the row comes back where #24707 placed it: last, after a separator.
    @Test func theNewTabMenuEndsWithInspectElementWhenTheInspectorIsOn() {
        let off = newTabRows(inspector: nil)
        #expect(newTabRows(inspector: true) == off + ["—", "agentPane.togglePointerInspector"])
    }
}
