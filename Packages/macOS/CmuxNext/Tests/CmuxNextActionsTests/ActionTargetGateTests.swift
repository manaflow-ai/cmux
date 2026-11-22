import AppKit
@testable import CmuxNextActions
import Testing

/// `ActionTargetVisibility.gate`: Open Desktop on a Cloud machine that reports no desktop is left
/// out of that machine's menu, its palette row is disabled with why, and every run is refused.
@MainActor @Suite struct ActionTargetGateTests {
    static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }

    @Test func aGatedActionIsHiddenRefusedAndDisabledOnlyForTheTargetThatLacksIt() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var runs: [String?] = []
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id, invoke: { runs.append(id == "cloudOpenDesktop" ? $0.target?.id : nil) })
        }
        let noDesktop = "vm-plain"
        ActionTargetVisibility.gate("cloudOpenDesktop", in: registry) { invocation in
            (invocation.target?.id ?? noDesktop) == noDesktop ? "no desktop" : nil
        }
        func shows(_ machine: String) -> Bool {
            let menu = registry.makeContextMenu(for: .cloudMachine, target: ActionTargetRef(kind: .machine, id: machine))
            return Self.items(menu).contains { ($0.representedObject as? ActionMenuPayload)?.id == "cloudOpenDesktop" }
        }
        #expect(shows("vm-desktop"))
        #expect(!shows(noDesktop))

        #expect(registry.perform("cloudOpenDesktop", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-desktop"))))
        #expect(!registry.perform("cloudOpenDesktop", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: noDesktop))))
        #expect(runs.compactMap { $0 } == ["vm-desktop"])
        #expect(registry.action(for: "cloudOpenDesktop")?.paletteUnavailableReason?() == "no desktop")
    }
}
