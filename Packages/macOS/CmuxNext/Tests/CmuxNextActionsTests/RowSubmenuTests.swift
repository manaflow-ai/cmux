import AppKit
@testable import CmuxNextActions
import Testing

/// Screen Sharing ▸ in the new tab ⌄ menu (Leo, 2026-11-18: "you should be able to click the chevron next to
/// teh + of new tab and just go there"): an action's row opens its owner's submenu and keeps its run.
@MainActor
struct RowSubmenuTests {
    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("macScreen.open", invoke: { _ in })
        return registry
    }

    private func screenRow(_ menu: NSMenu) -> NSMenuItem? {
        menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "macScreen.open" }
    }

    @Test func theNewTabMenusScreenSharingRowOpensTheOwnersSubmenu() throws {
        let registry = registry()
        let target = ActionTargetRef(kind: .pane, id: "p1")
        var asked: [ActionTargetRef?] = []
        registry.rowSubmenus["macScreen.open"] = { target, _ in
            asked.append(target)
            let menu = NSMenu()
            menu.addItem(withTitle: "cosmic-gray", action: nil, keyEquivalent: "")
            return menu
        }
        let row = try #require(screenRow(registry.makeContextMenu(for: .newTab, target: target)))
        #expect(row.submenu?.items.map(\.title) == ["cosmic-gray"])
        #expect(asked == [target])
        #expect(!row.title.hasSuffix("…"))
    }

    @Test func withoutASubmenuTheRowStaysPlain() throws {
        let registry = registry()
        registry.rowSubmenus["macScreen.open"] = { _, _ in nil }
        let row = try #require(screenRow(registry.makeContextMenu(for: .newTab)))
        #expect(row.submenu == nil)
    }
}
