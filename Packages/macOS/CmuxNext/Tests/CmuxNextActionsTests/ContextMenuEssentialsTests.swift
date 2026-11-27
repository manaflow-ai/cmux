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

    private static let sidebarTrimmedActions: [ActionID] = [
        "workspace.setTheme", "workspace.setTint", "workspace.removeAllColors",
        "sidebar.density.compact", "sidebar.density.comfortable",
        // Copy Workspace ID and Copy Workspace Link came back under More > Copy (#27709, classic parity).
        "sidebar.density.expanded", "workspace.copyPath", "palette.copyWorkspaceIDAndRef", "copyWorkspaceSSHError",
        "agentChat.copyIdentifier", "workspace.showResources", "revealWorkspaceInFinder",
        "palette.openWorkspacePullRequests", "workspace.setRemoteLocalhost",
    ]

    @Test func theWorkspaceMenuShowsTheFrequentRowsThenMore() {
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"))
        // The group rows keep their own top-level section (Lawrence 2026-10-14: "my groups UI is lost").
        // Move ▸ (its first row: Move to Top) stays on top (u2418: Move to Top of Group was not found under More).
        #expect(rows(menu) == ["renameWorkspace", "palette.toggleWorkspacePin", "palette.workspaceColor", "workspace.newBelow",
                               "home.messageAbout", "palette.moveWorkspaceToTop", "—",
                               "moveWorkspaceToGroup", "groupSelectedWorkspaces", "removeWorkspaceFromGroup", "—", "palette.copyWorkspaceLink", "More", "—",
                               "closeWorkspace"])
        // Move to Group > Frontend names the group as a target, as the handler needs.
        let groups = menu.items.first { ActionRegistry.menuRun(of: $0.submenu?.items.first ?? NSMenuItem())?.id == "moveWorkspaceToGroup" }
        let frontend = groups?.submenu?.items.first.flatMap(ActionRegistry.menuRun(of:))
        #expect(frontend?.arguments["group"] == .target(ActionTargetRef(kind: .workspaceGroup, id: "g1")))
        // The rest moved, not gone.
        #expect(allActions(menu).contains("palette.markWorkspaceUnread"))
        #expect(allActions(menu).contains("workspace.duplicate"))
    }

    /// Leo 2026-10-29: "I feel like there's a much better way of doing things than just all of these
    /// menus ... there's no link to workspace, which is, I mean, that seems pretty important". The
    /// workspace, tab and pane menus each have one Copy ▸ at their top level, just above More, whose
    /// first row is the right-clicked object's link, then its ID, then the other identifiers. (#27709 put the
    /// workspace's ID and link in More > Copy; they move up with the rest.)
    @Test(arguments: [
        (ActionMenuContext.workspaceRow, ActionTargetKind.workspace,
         ["palette.copyWorkspaceLink", "palette.copyWorkspaceID"]),
        (.tab, .tab, ["palette.copySurfaceLink", "palette.copySurfaceID", "palette.copyPaneLink", "palette.copyPaneID",
                      "palette.copyIdentifiers", "agentChat.copyIdentifier", "tab.screenshot"]),
        (.pane, .pane, ["palette.copyPaneLink", "palette.copyPaneID", "pane.screenshot"]),
    ] as [(ActionMenuContext, ActionTargetKind, [String])])
    func eachObjectMenuHasOneCopyFolderLinkFirst(context: ActionMenuContext, kind: ActionTargetKind, expected: [String]) throws {
        let menu = registry().makeContextMenu(for: context, target: ActionTargetRef(kind: kind, id: "x"))
        let copyTitle = MenuFolder.copy.title
        let copy = try #require(menu.items.first { $0.title == copyTitle }?.submenu, "\(context) has no top-level Copy")
        let ids = allActions(copy)
        // The link first, then the ID; every row the menu shows in the listed order.
        #expect(Array(ids.prefix(2)) == Array(expected.prefix(2)), "\(context)'s Copy: \(ids)")
        #expect(ids.filter(expected.contains) == expected.filter(ids.contains), "\(context)'s Copy: \(ids)")
        #expect(Set(ids).isSubset(of: expected), "\(context)'s Copy has rows the test does not name: \(ids)")
        // Just above More, and More has no loose copy rows left.
        let titles = menu.items.map(\.title)
        let at = try #require(titles.firstIndex(of: copyTitle))
        #expect(titles.indices.contains(at + 1) && titles[at + 1] == "More", "\(context): \(titles)")
        let more = menu.items.first { $0.title == "More" }?.submenu.map(allActions) ?? []
        #expect(Set(more).isDisjoint(with: expected), "\(context)'s More still has copy rows")
    }

    /// A selection's menu keeps the copy rows in More, as one Copy ▸ (never loose rows).
    @Test func theSelectionMenusMoreKeepsCopyAsOneFolder() throws {
        let entries = ContextMenuCatalog.shared.selectionEntries(for: .workspaceRow)
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"), entries: entries)
        let more = try #require(menu.items.first { $0.title == "More" }?.submenu)
        let copy = try #require(more.items.first { $0.title == MenuFolder.copy.title }?.submenu)
        #expect(allActions(copy) == ["palette.copyWorkspaceLink", "palette.copyWorkspaceID"])
    }

    /// Leo 2026-10-23: "I don't think anybody actually looks at most of the, like, row settings
    /// ... obviously don't remove things from being searchable in the command palette". The row's
    /// menu drops the global, copy and diagnostic long tail; the palette and the sidebar
    /// background menu keep them (SidebarMenuPaletteReachabilityTests).
    @Test func theWorkspaceRowMenuDropsTheGlobalAndDiagnosticLongTail() {
        let ids = Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .workspaceRow)))
        for id in Self.sidebarTrimmedActions {
            #expect(!ids.contains(id), "\(id) is still in the workspace row menu")
        }
    }

    /// A menu opened on one of several selected rows is Chrome's menu for several tabs (Leo
    /// 2026-10-20): New Workspace Below and Add to New Group; Duplicate, Move ▸, Pin, Mute; More;
    /// Close, Close Other and Close Below; then Reopen Closed. The color row is the header's swatches.
    @Test func theSelectionMenuFollowsChromesMenuForSeveralTabs() {
        let entries = ContextMenuCatalog.shared.selectionEntries(for: .workspaceRow)
        let menu = registry().makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "ws"), entries: entries)
        let shown = rows(menu)
        // One verb for a selection: the row is Group Selected Workspaces, the action Cmd-Shift-G runs,
        // not a second "Add to New Group" that does the same thing under another name.
        #expect(shown == ["palette.workspaceColor", "workspace.newBelow", "groupSelectedWorkspaces", "—",
                          "workspace.duplicate", "palette.moveWorkspaceToTop", "palette.toggleWorkspacePin", "workspace.toggleAudioMute", "—",
                          "More", "—", "closeWorkspace", "palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow", "—",
                          "reopenClosedWorkspace"])
        #expect(shown.filter { $0 != "—" }.count <= 12)
        // The rest moved into More, not gone.
        for id in ["renameWorkspace", "moveWorkspaceToGroup", "palette.closeWorkspacesAbove", "palette.markWorkspaceUnread"] {
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
        for id: ActionID in ["workspace.duplicate", "palette.toggleWorkspacePin", "workspace.toggleAudioMute"] {
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

    @Test func theTabAndPaneMenusKeepTheirFrequentRows() {
        let registry = registry()
        let tab = rows(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t")))
        #expect(tab.suffix(6) == ["closeTab", "closeOtherTabsInPane", "closeTabsToRight", "—", "palette.copySurfaceLink", "More"])
        // The group rows stay at the top (Lawrence 2026-10-14, "my groups UI is lost"; check-group-menus.py).
        #expect(["tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab"].allSatisfy(tab.contains))
        #expect(allActions(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))).contains("renameTab") && tab.contains("palette.toggleTabPin"))
        let pane = rows(registry.makeContextMenu(for: .pane, target: ActionTargetRef(kind: .pane, id: "p")))
        #expect(pane.suffix(3) == ["More", "—", "closePane"])
        #expect(pane.filter { $0 != "—" }.count <= 8)
        #expect(pane.contains("splitRight") && pane.contains("splitDown"))
    }

    /// New Tab to the Right and the group rows (Lawrence's guard, check-group-menus.py), then the
    /// frequent rows; moves remain in More.
    @Test func theTabMenuFollowsChromesOrder() {
        let menu = registry().makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let tab = rows(menu)
        #expect(tab == ["newTab.toRight", "tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab", "—",
                        "reloadTab", "duplicateTab", "palette.toggleTabPin", "toggleTabAudioMute",
                        "closeTab", "closeOtherTabsInPane", "closeTabsToRight", "—", "palette.copySurfaceLink", "More"])
        // The rest moved into More, not gone: Close Tabs to the Left (not in Chrome) and Move Tab to New Window.
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
