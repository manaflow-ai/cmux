import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// A sidebar right-click's menu, by target. The layout sections' menus stay
/// on SidebarBridge (SidebarBridge+Sections), which dispatches to these.
enum SidebarContextMenus {
    /// Every sidebar menu draws its rows with a wash of `scope`'s accent (the sidebar's), not the
    /// system's blue (#19754's follow-up); the workspace and group menus open with their name and
    /// colors. `trailing` rows end a workspace menu after a separator (a pinned tile's own rows).
    static func menu(for target: SidebarContextTarget, model: SidebarModel, services: AppServices, scope: ThemeScope,
                     trailing: [NSMenuItem] = []) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .tab(let workspace, let tab):
            // The tab's own menu, as on its strip; the row is not selected by the right-click.
            let model = services.locateTab(tab.rawValue)?.0
            let menu = PaneController.tabMenu(tab.rawValue, tab: model, keepsTab: TabPromotion.staysPut(tab: tab.rawValue, in: services.workspace(id: workspace.rawValue)),
                                              sameKind: NewTabKind.of(tab.rawValue, tab: model, services: services), registry: registry)
            menu.themeRows(in: scope)
            return menu
        case .workspaces(let ids):
            // A connecting SSH machine's row (cx-gaq9) has its machine's menu: Reconnect, Disconnect, Forget.
            if ids.count == 1, let machine = ids.first.flatMap(SSHConnectingRows.machine(of:)) {
                return registry.makeContextMenu(for: .sshMachine, target: ActionTargetRef(kind: .machine, id: machine)).themeRows(in: scope)
            }
            // A placeholder row is no workspace yet: no menu, not one that does nothing.
            guard let first = ids.first, !ids.contains(where: { model.isPlaceholder($0) || CloudCreationRows.isRow($0, services) }) else { return nil }
            // Dismiss Highlight shows only while the row's workspace draws an attention ring (cx-epgo).
            let highlighted = services.daemon.store.workspaces.first { $0.id == first.rawValue }.map(services.notifications.hasHighlight) ?? false
            // Several selected rows get Chrome's menu for several tabs (ContextMenuEssentials.selectionMenus).
            let catalog = ContextMenuCatalog.shared, selection = ids.count > 1
            let all = selection ? catalog.selectionEntries(for: .workspaceRow) : catalog.entries(for: .workspaceRow)
            let entries = highlighted ? all : ContextMenuCatalog.removing(["notifications.dismissHighlight"], from: all)
            let target = ActionTargetRef(kind: .workspace, id: first.rawValue)
            let menu = registry.makeContextMenu(for: .workspaceRow, target: target, entries: entries)
            // The name field renames the clicked row only, so a multi-row selection gets just the swatches.
            // A pinned workspace's tile has no row in the list model; its name comes from the workspace.
            let title = model.workspace(first)?.title ?? services.workspace(id: first.rawValue)?.displayName ?? ""
            MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: selection ? nil : title,
                                       rename: "renameWorkspace")
            if !trailing.isEmpty {
                menu.addItem(.separator())
                for item in trailing { menu.addItem(item) }
            }
            if selection { nameSelection(menu, ids, services) }
            menu.themeRows(in: scope)
            return menu
        case .group(let id):
            let target = ActionTargetRef(kind: .workspaceGroup, id: id.rawValue)
            let menu = registry.makeContextMenu(for: .workspaceGroup, target: target)
            let group = model.group(id)
            // cmux.json `workspaceGroups.byCwd`: the group's own rows, after the menu's first group.
            let configured = WorkspaceGroupConfigLook(config: services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig(), machines: services.machines)
                .menuItems(for: group, target: target, registry: registry)
            if !configured.isEmpty {
                var at = menu.items.firstIndex(where: \.isSeparatorItem) ?? menu.items.count
                menu.insertItem(.separator(), at: at)
                for item in configured {
                    at += 1
                    menu.insertItem(item, at: at)
                }
            }
            MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: group?.name ?? "", rename: "workspaceGroup.rename",
                                       current: group?.custom == nil ? group?.color : nil, noColor: group?.tint == GroupTint.none)
            menu.themeRows(in: scope)
            return menu
        case .section(.machine(let machine)) where machine.rawValue == MachineRegistry.localID && SidebarSection.machineCount(model.sections) == 1:
            // This Mac alone: its header is the list's "Projects" title and draws no machine icon.
            return registry.makeContextMenu(for: .sidebarBackground).themeRows(in: scope)
        case .section(.machine(let machine)):
            return machineMenu(machine.rawValue, services: services).themeRows(in: scope)
        case .section, .background:
            return registry.makeContextMenu(for: .sidebarBackground).themeRows(in: scope)
        case .footer:
            // Show for each piece hidden from the band (cx-wab7m); with none hidden, the sidebar's menu.
            let band: NSMenu? = registry.makeContextMenu(for: .sidebarFooter)
            if let band, band.items.contains(where: { !$0.isSeparatorItem }) { return band.themeRows(in: scope) }
            return registry.makeContextMenu(for: .sidebarBackground).themeRows(in: scope)
        case .profile(let id):
            return registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: id.rawValue)).themeRows(in: scope)
        case .nowPlaying:
            // The media card's rows (u2437): Play/Pause, Picture in Picture (on the tab the card
            // shows), Hide, Hide Until Relaunch, Never Show Media Card.
            let menu = registry.makeContextMenu(for: .nowPlayingCard,
                                                arguments: [PictureInPictureHandlers.cardArgument: .bool(true)])
            menu.themeRows(in: scope)
            return menu
        case .priorityChat(let id):
            // A Priority row: the actions its hover buttons run, on its chat.
            return registry.makeContextMenu(for: .priorityRow, target: SidebarPriorityRowActions.target(id)).themeRows(in: scope)
        case .layoutItem, .layoutSection:
            return nil
        }
    }

    /// A multi-selection's menu says what its rows do to every selected row: Pin pins them when
    /// the menu's target (the first selected row) is unpinned, as the pin action decides, and Mute
    /// mutes them while one plays.
    private static func nameSelection(_ menu: NSMenu, _ ids: [CmuxNextSidebar.WorkspaceID], _ services: AppServices) {
        let workspaces = ids.compactMap { services.workspace(id: $0.rawValue) }
        let pins = workspaces.first.map { !PinCommands(context: AppActionContext(services: services)).isWorkspacePinned($0) } ?? true
        menu.namingWorkspaceSelection(pins: pins, mutes: BrowserTabAudio.audio(of: workspaces, cache: services.cache) != .muted)
    }

    /// The most top-level rows a right-click menu shows (ActionSurfaceParityTests).
    static let topLevelLimit = 12

    /// A machine header's menu: its own (an SSH or Cloud machine's; this
    /// Mac's and a paired server's are the sidebar's), with what every
    /// machine offers (`machineSection`: its icon) after the first group,
    /// or at the end of its Options folder when the top level is full.
    static func machineMenu(_ machine: String, services: AppServices) -> NSMenu {
        let registry = services.registry, machines = services.machines
        let target = ActionTargetRef(kind: .machine, id: machine)
        let menu = if machines.sshSession(machine) != nil {
            registry.makeContextMenu(for: .sshMachine, target: target)
        } else if machines.server(machine) != nil || machine == MachineRegistry.localID {
            registry.makeContextMenu(for: .sidebarBackground)
        } else {
            registry.makeContextMenu(for: .cloudMachine, target: target)
        }
        let shared = registry.makeContextMenu(for: .machineSection, target: target)
        let items = shared.items
        shared.removeAllItems()
        guard !items.isEmpty else { return menu }
        if menu.items.filter({ !$0.isSeparatorItem }).count >= Self.topLevelLimit,
           let options = menu.items.first(where: { $0.title == MenuFolder.options.title })?.submenu {
            options.addItem(.separator())
            for item in items { options.addItem(item) }
            return menu
        }
        var at = menu.items.firstIndex(where: \.isSeparatorItem) ?? menu.items.count
        if at > 0 {
            menu.insertItem(.separator(), at: at)
            at += 1
        }
        for item in items {
            menu.insertItem(item, at: at)
            at += 1
        }
        if at < menu.items.count, !menu.items[at].isSeparatorItem { menu.insertItem(.separator(), at: at) }
        return menu
    }
}
