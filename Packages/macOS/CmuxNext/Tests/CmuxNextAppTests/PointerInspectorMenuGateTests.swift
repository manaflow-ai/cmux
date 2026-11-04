import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Inspect Element (#24707, the UI pointer inspector) is a feature Leo asked for (ask-5077a4ec48),
/// so it ships on, for web content only: the agent chat page's menu offers it (in Tools), and
/// leaves it out once Debug Settings' "UI pointer inspector" is turned off. Native menus such as
/// the tab bar's + never offer it.
@MainActor @Suite(.serialized) struct PointerInspectorMenuGateTests {
    private static let inspector: ActionID = "agentPane.togglePointerInspector"

    /// Every row's action in `menu` and its submenus.
    private func ids(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + (item.submenu.map(ids) ?? [])
        }
    }

    private func rows(for context: ActionMenuContext, inspector on: Bool?) -> [String] {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, on.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        // The gate applies to a bound action, as AgentHandlers binds it first.
        registry.bind(Self.inspector, invoke: { _ in })
        AgentHandlers.gatePointerInspectorMenuRows(in: registry)
        let target = context == .agentChat ? ActionTargetRef(kind: .tab, id: "tab_chat") : ActionTargetRef(kind: .pane, id: "p")
        return ids(registry.makeContextMenu(for: context, target: target))
    }

    @Test func theInspectorIsOnByDefault() {
        #expect(AgentPaneTunables.pointerInspector.defaultValue == true)
    }

    @Test func theAgentChatMenuOffersInspectElementByDefault() {
        for on in [nil, true] as [Bool?] {
            #expect(rows(for: .agentChat, inspector: on).contains(Self.inspector.rawValue))
        }
    }

    @Test func theAgentChatMenuLeavesInspectElementOutWhenTheInspectorIsOff() {
        #expect(!rows(for: .agentChat, inspector: false).contains(Self.inspector.rawValue))
    }

    @Test func theNewTabMenuNeverOffersInspectElement() {
        for on in [nil, true, false] as [Bool?] {
            let rows = rows(for: .newTab, inspector: on)
            #expect(!rows.contains(Self.inspector.rawValue), "\(rows)")
            #expect(rows.first == "newSurface", "\(rows)")
        }
    }
}
