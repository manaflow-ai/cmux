import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Inspect Element (#24707, the UI pointer inspector) is a feature Leo asked for (ask-5077a4ec48),
/// so it ships on: the tab bar's + menu ends with it, last in its own group, and leaves it out
/// only once Debug Settings' "UI pointer inspector" is turned off.
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

    @Test func theInspectorIsOnByDefault() {
        #expect(AgentPaneTunables.pointerInspector.defaultValue == true)
    }

    @Test func theNewTabMenuLeavesInspectElementOutWhenTheInspectorIsOff() {
        let off = newTabRows(inspector: false)
        #expect(!off.contains("agentPane.togglePointerInspector"), "\(off)")
        #expect(off.first == "newSurface" && off.last != "—", "\(off)")
    }

    /// On (the default), the row is where #24707 placed it: last, after a separator.
    @Test func theNewTabMenuEndsWithInspectElementByDefault() {
        let off = newTabRows(inspector: false)
        for on in [newTabRows(inspector: nil), newTabRows(inspector: true)] {
            #expect(on == off + ["—", "agentPane.togglePointerInspector"], "\(on)")
        }
    }
}
