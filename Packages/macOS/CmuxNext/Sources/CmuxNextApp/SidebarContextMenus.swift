import AppKit
import CmuxNextActions
import CmuxNextSidebar

/// A sidebar right-click's menu, by target. The layout sections' menus stay
/// on SidebarBridge (SidebarBridge+Sections), which dispatches to these.
enum SidebarContextMenus {
    static func menu(for target: SidebarContextTarget, model: SidebarModel, services: AppServices) -> NSMenu? {
        let registry = services.registry
        switch target {
        case .tab(let workspace, let tab):
            // The tab's own menu, as on its strip; the row is not selected by the right-click.
            return PaneController.tabMenu(tab.rawValue, tab: services.locateTab(tab.rawValue)?.0,
                                          workspaceKind: services.workspace(id: workspace.rawValue)?.kind, registry: registry)
        case .workspaces(let ids):
            // A placeholder row is no workspace yet: no menu, not one that does nothing.
            guard let first = ids.first, !ids.contains(where: { model.workspace($0)?.rowState == .placeholder || CloudCreationRows.isRow($0, services) }) else { return nil }
            return registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: first.rawValue))
        case .group(let id):
            return registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: id.rawValue))
        case .section(.machine(let machine)) where services.machines.sshSession(machine.rawValue) != nil:
            return registry.makeContextMenu(for: .sshMachine, target: ActionTargetRef(kind: .machine, id: machine.rawValue))
        case .section(.machine(let machine)) where services.machines.server(machine.rawValue) != nil:
            return registry.makeContextMenu(for: .sidebarBackground)
        case .section(.machine(let machine)) where machine.rawValue != MachineRegistry.localID:
            return registry.makeContextMenu(for: .cloudMachine, target: ActionTargetRef(kind: .machine, id: machine.rawValue))
        case .section, .background:
            return registry.makeContextMenu(for: .sidebarBackground)
        case .profile(let id):
            return registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: id.rawValue))
        case .layoutItem, .layoutSection:
            return nil
        }
    }
}
