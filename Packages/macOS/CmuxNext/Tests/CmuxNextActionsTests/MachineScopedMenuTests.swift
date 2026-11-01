import AppKit
@testable import CmuxNextActions
import Testing

/// A forked or SSH machine keeps this Mac's tab and workspace ids, so a right-click menu on its
/// object names its machine on every row: shown, titled, previewed and run there
/// (manaflow-ai/cmuxterm-hq#5338). Only one row (Mark Unread) used to carry it.
@MainActor @Suite struct MachineScopedMenuTests {
    final class Recorder {
        let registry = ActionRegistry.standard()
        var runs: [(ActionID, ActionInvocation)] = []
        var previews: [String?] = []
        var hiddenFor: [String?] = []

        init() {
            registry.context = ActionContext(rawValue: .max)
            for descriptor in ActionCatalog.all {
                let id = descriptor.id
                registry.bind(id, invoke: { [unowned self] in runs.append((id, $0)) })
            }
            ActionTargetVisibility.hide("renameWorkspace", in: registry) { [unowned self] in hiddenFor.append($0.targetMachineID); return false }
            registry.targetChoices = { _, kind, _ in
                kind == .profile ? ActionTargetChoices(cases: [ActionEnumCase(value: "work", title: "Work"), ActionEnumCase(value: "home", title: "Home")]) : nil
            }
            registry.choicePreview = { [unowned self] _, _, _, _, machineID in previews.append(machineID) }
        }
    }

    static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }

    @Test func everyRowOfAMachineScopedMenuRunsOnThatMachine() throws {
        let recorder = Recorder()
        let target = ActionTargetRef(kind: .workspace, id: "w1")
        let menu = recorder.registry.makeContextMenu(for: .workspaceRow, target: target, machineID: "fork-1")
        let payloads = Self.items(menu).compactMap { $0.representedObject as? ActionMenuPayload }
        #expect(payloads.count > 5)
        #expect(payloads.allSatisfy { $0.targetMachineID == "fork-1" }, "rows without the machine: \(payloads.filter { $0.targetMachineID != "fork-1" }.map(\.id))")
        #expect(recorder.hiddenFor == ["fork-1"], "a row's visibility was judged without its machine")

        // A choices submenu (Move Workspace to Space ▸ Home) runs and previews on the machine too.
        let home = try #require(Self.items(menu).first { ($0.representedObject as? ActionMenuPayload)?.id == "workspace.moveToSpace" && $0.title == "Home" })
        let submenu = try #require(home.menu)
        let coordinator = try #require(recorder.registry.choiceCoordinators.object(forKey: submenu))
        coordinator.menu(submenu, willHighlight: home)
        #expect(recorder.previews == ["fork-1"])
        _ = (home.target as? NSObject)?.perform(home.action, with: home)
        #expect(recorder.runs.last?.0 == "workspace.moveToSpace")
        #expect(recorder.runs.last?.1.targetMachineID == "fork-1")
    }

    @Test func anUnscopedMenuNamesNoMachine() {
        let recorder = Recorder()
        let menu = recorder.registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "w1"))
        let payloads = Self.items(menu).compactMap { $0.representedObject as? ActionMenuPayload }
        #expect(!payloads.isEmpty && payloads.allSatisfy { $0.targetMachineID == nil })
        #expect(recorder.hiddenFor == [nil])
    }
}
