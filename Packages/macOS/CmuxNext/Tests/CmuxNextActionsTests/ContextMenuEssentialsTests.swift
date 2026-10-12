import AppKit
@testable import CmuxNextActions
import Testing

/// The workspace, tab and pane menus show the few rows people use, then one More submenu with
/// everything else, then Close (Leo 2026-10-11: the twelve-row menu was "overwhelming").
@MainActor
struct ContextMenuEssentialsTests {
    /// Each top-level row as the action it runs (a choices row: its submenu's action), "More"
    /// for the More submenu, "—" for a separator.
    private func rows(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if let id = ActionRegistry.menuRun(of: item)?.id { return id.rawValue }
            if item.title == "More" { return "More" }
            return item.submenu?.items.lazy.compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue }.first ?? item.title
        }
    }

    /// Every action a menu runs, submenus included.
    private func allActions(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item in
            (ActionRegistry.menuRun(of: item).map { [$0.id.rawValue] } ?? []) + (item.submenu.map(allActions) ?? [])
        }
    }

    private func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        // A picker row shows only for a bound action (the app binds both).
        for id: ActionID in ["palette.workspaceColor", "moveWorkspaceToGroup"] { registry.bind(id, invoke: { _ in }) }
        registry.targetChoices = { _, kind, _ in
            kind == .workspaceGroup ? ActionTargetChoices(cases: [ActionEnumCase(value: "g1", title: "Frontend")]) : nil
        }
        return registry
    }

    @Test func theWorkspaceMenuShowsTheFrequentRowsThenMore() {
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        #expect(rows(menu) == ["renameWorkspace", "palette.toggleWorkspacePin", "palette.workspaceColor", "workspace.newBelow",
                               "moveWorkspaceToGroup", "More", "—", "closeWorkspace"])
        // The rest moved, not gone.
        #expect(allActions(menu).contains("palette.copyWorkspaceID"))
        #expect(allActions(menu).contains("workspace.duplicate"))
    }

    /// A row that only says it is not in this version never ships.
    @Test func noMenuOffersCustomWorkspaceColor() {
        let registry = registry()
        #expect(registry.descriptor(for: "palette.workspaceCustomColor") == nil)
        let menu = registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        #expect(!allActions(menu).contains("palette.workspaceCustomColor"))
    }

    @Test func theTabAndPaneMenusEndWithMoreAndClose() {
        let registry = registry()
        let tab = rows(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t")))
        #expect(tab.suffix(3) == ["More", "—", "closeTab"])
        #expect(tab.filter { $0 != "—" }.count <= 7)
        #expect(tab.contains("renameTab") && tab.contains("palette.toggleTabPin"))
        let pane = rows(registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p")))
        #expect(pane.suffix(3) == ["More", "—", "closePane"])
        #expect(pane.filter { $0 != "—" }.count <= 7)
        #expect(pane.contains("splitRight") && pane.contains("splitDown"))
    }
}
