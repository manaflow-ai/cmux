import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar

/// A sidebar right-click's menu, by target. The layout sections' menus stay
/// on SidebarBridge (SidebarBridge+Sections), which dispatches to these.
enum SidebarContextMenus {
    /// The workspace and tab menus draw their rows in `scope`'s accent (the sidebar's), not the
    /// system's (#19754's follow-up).
    static func menu(for target: SidebarContextTarget, model: SidebarModel, services: AppServices, scope: ThemeScope) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .tab(let workspace, let tab):
            // The tab's own menu, as on its strip; the row is not selected by the right-click.
            let model = services.locateTab(tab.rawValue)?.0
            let menu = PaneController.tabMenu(tab.rawValue, tab: model, workspaceKind: services.workspace(id: workspace.rawValue)?.kind,
                                              sameKind: NewTabKind.of(tab.rawValue, tab: model, services: services), registry: registry)
            menu.themeRows(in: scope)
            return menu
        case .workspaces(let ids):
            // A connecting SSH machine's row (cx-gaq9) has its machine's menu: Reconnect, Disconnect, Forget.
            if ids.count == 1, let machine = ids.first.flatMap(SSHConnectingRows.machine(of:)) {
                return registry.makeContextMenu(for: .sshMachine, target: ActionTargetRef(kind: .machine, id: machine))
            }
            // A placeholder row is no workspace yet: no menu, not one that does nothing.
            guard let first = ids.first, !ids.contains(where: { model.isPlaceholder($0) || CloudCreationRows.isRow($0, services) }) else { return nil }
            // Dismiss Highlight shows only while the row's workspace draws an attention ring (cx-epgo).
            let highlighted = services.daemon.store.workspaces.first { $0.id == first.rawValue }.map(services.notifications.hasHighlight) ?? false
            let entries = highlighted ? nil : ContextMenuCatalog.shared.entries(for: .workspaceRow, removing: ["notifications.dismissHighlight"])
            let menu = registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: first.rawValue), entries: entries)
            WorkspaceColorSwatchRow.inline(in: menu)
            menu.themeRows(in: scope)
            return menu
        case .group(let id):
            return registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: id.rawValue))
        case .section(.machine(let machine)) where machine.rawValue == MachineRegistry.localID && SidebarSection.machineCount(model.sections) == 1:
            // This Mac alone: its header is the list's "Projects" title and draws no machine icon.
            return registry.makeContextMenu(for: .sidebarBackground)
        case .section(.machine(let machine)):
            return machineMenu(machine.rawValue, services: services)
        case .section, .background:
            return registry.makeContextMenu(for: .sidebarBackground)
        case .footer:
            // Show for each piece hidden from the band (cx-wab7m); with none hidden, the sidebar's menu.
            let band: NSMenu? = registry.makeContextMenu(for: .sidebarFooter)
            if let band, band.items.contains(where: { !$0.isSeparatorItem }) { return band }
            return registry.makeContextMenu(for: .sidebarBackground)
        case .profile(let id):
            return registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: id.rawValue))
        case .nowPlaying:
            // The media card's rows (u2437): Play/Pause, Hide, Hide Until Relaunch, Never Show Media Card.
            let menu = registry.makeContextMenu(for: .nowPlayingCard)
            menu.themeRows(in: scope)
            return menu
        case .layoutItem, .layoutSection:
            return nil
        }
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
