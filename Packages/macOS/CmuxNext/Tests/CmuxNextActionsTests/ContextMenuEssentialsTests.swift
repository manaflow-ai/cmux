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
        #expect(rows(menu) == ["renameWorkspace", "palette.toggleWorkspacePin", "palette.workspaceColor", "workspace.newBelow", "workspace.duplicate",
                               "home.messageAbout", "palette.moveWorkspaceToTop", "—",
                               "moveWorkspaceToGroup", "groupSelectedWorkspaces", "removeWorkspaceFromGroup", "—", "More", "—", "closeWorkspace"])
        // Move to Group > Frontend names the group as a target, as the handler needs.
        let groups = menu.items.first { ActionRegistry.menuRun(of: $0.submenu?.items.first ?? NSMenuItem())?.id == "moveWorkspaceToGroup" }
        let frontend = groups?.submenu?.items.first.flatMap(ActionRegistry.menuRun(of:))
        #expect(frontend?.arguments["group"] == .target(ActionTargetRef(kind: .workspaceGroup, id: "g1")))
        // The rest moved, not gone.
        #expect(allActions(menu).contains("palette.copyWorkspaceID"))
        #expect(allActions(menu).contains("workspace.duplicate"))
    }

    /// A menu opened on one of several selected rows is Chrome's menu for several tabs (Leo
    /// 2026-10-20): New Workspace Below and Add to New Group; Duplicate, Move ▸, Pin, Mute; More;
    /// Close, Close Other and Close Below; then Reopen Closed. The color row is the header's swatches.
    @Test func theSelectionMenuFollowsChromesMenuForSeveralTabs() {
        let entries = ContextMenuCatalog.shared.selectionEntries(for: .workspaceRow)
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"), entries: entries)
        let shown = rows(menu)
        #expect(shown == ["palette.workspaceColor", "workspace.newBelow", "workspace.moveToNewGroup", "—",
                          "workspace.duplicate", "palette.moveWorkspaceToTop", "palette.toggleWorkspacePin", "workspace.toggleAudioMute", "—",
                          "More", "—", "closeWorkspace", "palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow", "—",
                          "reopenClosedWorkspace"])
        #expect(shown.filter { $0 != "—" }.count <= 12)
        // The rest moved into More, not gone.
        for id in ["renameWorkspace", "moveWorkspaceToGroup", "palette.closeWorkspacesAbove", "palette.copyWorkspaceID"] {
            #expect(allActions(menu).contains(id), "\(id)")
        }
    }

    /// A one-row menu keeps its layout; Reopen Closed Workspace joins its More (Close section).
    @Test func theOneRowMenuOffersReopenClosedInMore() {
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        #expect(!rows(menu).contains("reopenClosedWorkspace"))
        #expect(allActions(menu).contains("reopenClosedWorkspace"))
    }

    /// The selection menu's rows say they act on every selected workspace, each way of a toggle.
    @Test func theSelectionMenuNamesItsRowsForTheSelection() {
        let entries = ContextMenuCatalog.shared.selectionEntries(for: .workspaceRow)
        func titles(pins: Bool, mutes: Bool) -> [ActionID: String] {
            let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"), entries: entries)
                .namingWorkspaceSelection(pins: pins, mutes: mutes)
            return Dictionary(menu.items.compactMap { item in ActionRegistry.menuRun(of: item).map { ($0.id, item.title) } }) { first, _ in first }
        }
        let on = titles(pins: true, mutes: true), off = titles(pins: false, mutes: false)
        for id: ActionID in ["workspace.moveToNewGroup", "workspace.duplicate", "palette.toggleWorkspacePin", "workspace.toggleAudioMute"] {
            #expect(on[id] == NSMenu.workspaceSelectionTitle(id, pins: true, mutes: true), "\(id)")
        }
        #expect(on["palette.toggleWorkspacePin"] != off["palette.toggleWorkspacePin"])
        #expect(on["workspace.toggleAudioMute"] != off["workspace.toggleAudioMute"])
        // A row with no selection wording keeps the action's title.
        #expect(NSMenu.workspaceSelectionTitle("workspace.newBelow", pins: true, mutes: true) == nil)
        #expect(on["workspace.newBelow"] == registry().title(for: "workspace.newBelow"))
    }

    /// A row that only says it is not in this version never ships.
    @Test func noMenuOffersCustomWorkspaceColor() {
        let registry = registry()
        #expect(registry.descriptor(for: "palette.workspaceCustomColor") == nil)
        let menu = registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        #expect(!allActions(menu).contains("palette.workspaceCustomColor"))
    }

    @Test func theTabMenuKeepsEightProminentRowsAndMore() {
        let registry = registry()
        let menu = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let tab = rows(menu)
        #expect(tab == ["newTab.toRight", "reloadTab", "duplicateTab", "palette.toggleTabPin", "toggleTabAudioMute",
                        "closeTab", "closeOtherTabsInPane", "closeTabsToRight", "—", "More"])
        // Conditional essentials (PiP, agent identity and SSH disconnect) remain in the
        // catalog; their target visibility keeps them out when they do not apply.
        #expect(allActions(menu).count == 50)
        #expect(allActions(menu).contains("renameTab") && tab.contains("palette.toggleTabPin"))
        #expect(["tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab"].allSatisfy { id in
            allActions(menu).contains(id)
        })
        for id in ContextMenuEssentials.tabMenuTrimmedActions {
            #expect(!allActions(menu).contains(id), "\(id) stays out of the pointer menu")
        }
    }

    @Test func thePaneMenuStillEndsWithMoreAndClose() {
        let registry = registry()
        let pane = rows(registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p")))
        #expect(pane.suffix(3) == ["More", "—", "closePane"])
        #expect(pane.filter { $0 != "—" }.count <= 7)
        #expect(pane.contains("splitRight") && pane.contains("splitDown"))
    }

    /// The compact tab menu follows Chrome's useful order (`TabMenuModel::Build`; Leo 2026-10-19):
    /// New Tab to the Right, Reload, Duplicate, Pin, Mute and the three close rows, then More.
    @Test func theTabMenuFollowsChromesOrder() {
        let menu = registry().makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let tab = rows(menu)
        #expect(tab == ["newTab.toRight", "reloadTab", "duplicateTab", "palette.toggleTabPin", "toggleTabAudioMute",
                        "closeTab", "closeOtherTabsInPane", "closeTabsToRight", "—", "More"])
        // The rest stays in More, not gone: group actions, Close Tabs to the Left and Move Tab to New Window.
        for id in ["closeTabsToLeft", "tab.moveToNewWindow", "renameTab", "tab.restart"] {
            #expect(allActions(menu).contains(id), "\(id)")
        }
    }
}

/// Every right-click row shows its action's icon, as Chrome's menus do (Leo 2026-10-20), and a
/// folder its own; an action with only the catalog's placeholder symbol shows none.
@MainActor
struct ContextMenuIconTests {
    @Test func theWorkspaceMenusRowsAndFoldersHaveIcons() throws {
        let registry = ActionRegistry.standard()
        registry.bind("moveWorkspaceToGroup", invoke: { _ in })
        let menu = registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(!rows.isEmpty)
        for item in rows {
            #expect(item.image != nil, "\(item.title) has no icon")
            #expect(item.image?.isTemplate != false, "\(item.title)'s icon takes the row's ink")
        }
        #expect(ActionRegistry.menuIcon("command") == nil)
        #expect(ActionRegistry.menuIcon("pin") != nil)
    }
}
