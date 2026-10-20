import AppKit
@testable import CmuxNextActions
import Testing

/// The workspace, tab and pane menus show the few rows people use, their group rows, then one
/// More submenu with everything else, then Close (Leo 2026-10-11: the twelve-row menu was "overwhelming").
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
        // The group rows keep their own top-level section (Lawrence 2026-10-14: "my groups UI is lost").
        // Move ▸ (its first row: Move to Top) stays on top (u2418: Move to Top of Group was not found under More).
        #expect(rows(menu) == ["renameWorkspace", "palette.toggleWorkspacePin", "palette.workspaceColor", "workspace.newBelow",
                               "palette.moveWorkspaceToTop", "—",
                               "moveWorkspaceToGroup", "groupSelectedWorkspaces", "removeWorkspaceFromGroup", "—", "More", "—", "closeWorkspace"])
        // Move to Group > Frontend names the group as a target, as the handler needs.
        let groups = menu.items.first { ActionRegistry.menuRun(of: $0.submenu?.items.first ?? NSMenuItem())?.id == "moveWorkspaceToGroup" }
        let frontend = groups?.submenu?.items.first.flatMap(ActionRegistry.menuRun(of:))
        #expect(frontend?.arguments["group"] == .target(ActionTargetRef(kind: .workspaceGroup, id: "g1")))
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
        #expect(tab.suffix(5) == ["More", "—", "closeTab", "closeOtherTabsInPane", "closeTabsToRight"])
        #expect(["tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab"].allSatisfy(tab.contains))
        #expect(allActions(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))).contains("renameTab") && tab.contains("palette.toggleTabPin"))
        let pane = rows(registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p")))
        #expect(pane.suffix(3) == ["More", "—", "closePane"])
        #expect(pane.filter { $0 != "—" }.count <= 7)
        #expect(pane.contains("splitRight") && pane.contains("splitDown"))
    }

    /// The tab menu is Chrome's, in its order (`TabMenuModel::Build`; Leo 2026-10-19): New Tab to
    /// the Right and the group rows; Reload, Duplicate, Pin, Mute; then Close Tab, Close Other Tabs
    /// and Close Tabs to the Right at the top level, not in More.
    @Test func theTabMenuFollowsChromesOrder() {
        let menu = registry().makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let tab = rows(menu)
        #expect(tab == ["newTab.toRight", "tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab", "—",
                        "reloadTab", "duplicateTab", "palette.toggleTabPin", "toggleTabAudioMute",
                        "More", "—", "closeTab", "closeOtherTabsInPane", "closeTabsToRight"])
        // The rest moved into More, not gone: Close Tabs to the Left (not in Chrome) and Move Tab to New Window.
        for id in ["closeTabsToLeft", "tab.moveToNewWindow", "renameTab", "tab.restart", "browser.resetPinnedTab"] {
            #expect(allActions(menu).contains(id), "\(id)")
        }
    }
}
