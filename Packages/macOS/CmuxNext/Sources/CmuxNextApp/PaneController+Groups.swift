import CmuxNextDaemon
import CmuxNextTabs

// Chrome-style tab group intents -> daemon tab group commands. The strip
// applies nothing itself; the store echo updates it. Any rejection
// (including a daemon without tab-groups-v1) re-pushes the daemon's
// authoritative membership into the strip.
extension PaneController {
    func handleGroup(_ intent: TabStripIntent) {
        let handle = pane.handle
        switch intent {
        case .toggleGroupCollapsed(let id):
            let group = TabGroupID_(id)
            let collapsed = !(stripModel.group(id)?.isCollapsed ?? false)
            if collapsed, let selected = stripModel.selectedID, stripModel.tab(selected)?.groupID == id,
               let outside = stripModel.orderedTabs.first(where: { $0.groupID != id }) {
                select(outside.id)
            }
            groupCommand("update-tab-group", patch: .setTabGroupCollapsed(group, collapsed: collapsed)) { connection, transaction in
                _ = try await connection.updateTabGroup(group, collapsed: collapsed, transaction: transaction)
            }
        case .moveGroup(let id, let to):
            let group = TabGroupID_(id)
            groupCommand("move-tab-group") { connection, transaction in
                _ = try await connection.moveTabGroup(group, to: handle, index: to, transaction: transaction)
            }
        case .addToGroup(let tabID, let id, let index):
            guard let surface = tab(tabID)?.surface else { return }
            let group = TabGroupID_(id)
            groupCommand("add-tabs-to-group") { connection, transaction in
                _ = try await connection.addTabs([surface], toGroup: group, index: index, transaction: transaction)
            }
        case .removeFromGroup(let tabID, _):
            guard let surface = tab(tabID)?.surface else { return }
            groupCommand("remove-tabs-from-group") { connection, transaction in
                _ = try await connection.removeTabsFromGroup([surface], transaction: transaction)
            }
        case .createGroup(let item, let tabs):
            let surfaces = tabs.compactMap { tab($0)?.surface }
            let name = item.name, color = item.colorToken.rawValue
            groupCommand("create-tab-group") { connection, transaction in
                _ = try await connection.createTabGroup(in: handle, tabs: surfaces, name: name, color: color, transaction: transaction)
            }
        case .group(let command):
            run(command)
        default:
            break
        }
    }

    /// Runs a group command from the editor bubble, a menu, or the palette.
    func run(_ command: TabGroupCommand) {
        let group = TabGroupID_(command.groupID)
        switch command {
        case .rename(_, let name):
            groupCommand("update-tab-group") { c, t in _ = try await c.updateTabGroup(group, name: name, transaction: t) }
        case .setColor(_, let color):
            groupCommand("update-tab-group") { c, t in _ = try await c.updateTabGroup(group, color: .set(color.rawValue), transaction: t) }
        case .newTab:
            newTerminalTab()
        case .ungroup:
            groupCommand("ungroup-tab-group") { c, t in _ = try await c.ungroupTabGroup(group, transaction: t) }
        case .close:
            groupCommand("close-tab-group") { c, t in _ = try await c.closeTabGroup(group, transaction: t) }
        case .moveToNewWindow:
            groupCommand("move-tab-group-to-new-workspace") { c, t in _ = try await c.moveTabGroupToNewWorkspace(group, transaction: t) }
        case .save:
            groupCommand("save-tab-group") { c, _ in _ = try await c.saveTabGroup(group) }
        case .unsave:
            let saved = services.daemon.store.savedTabGroups.first { $0.openGroup == group }?.id
            guard let saved else { return }
            groupCommand("unsave-tab-group") { c, _ in try await c.unsaveTabGroup(saved) }
        }
    }

    /// After a drag moved `tab` into this pane: joins `group` (or leaves its
    /// group when nil) if membership differs. Needs tab-groups-v1.
    func syncGroupMembership(of tab: TabModel, to group: String?) {
        guard tab.tabGroup?.rawValue != group, services.daemon.supports(DaemonCapabilities.tabGroups) else { return }
        let surface = tab.surface
        if let group {
            let id = CmuxNextDaemon.TabGroupID(rawValue: group)
            groupCommand("add-tabs-to-group") { c, t in _ = try await c.addTabs([surface], toGroup: id, transaction: t) }
        } else {
            groupCommand("remove-tabs-from-group") { c, t in _ = try await c.removeTabsFromGroup([surface], transaction: t) }
        }
    }

    private func groupCommand(_ label: String, patch: OptimisticPatch = .custom { _ in },
                              _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        Task {
            let ok = await services.daemon.perform(label, patch: patch, body)
            if !ok { resyncStrip() }
        }
    }
}

/// Daemon tab group id from the strip's id.
private func TabGroupID_(_ id: CmuxNextTabs.TabGroupID) -> CmuxNextDaemon.TabGroupID {
    CmuxNextDaemon.TabGroupID(rawValue: id.rawValue)
}
