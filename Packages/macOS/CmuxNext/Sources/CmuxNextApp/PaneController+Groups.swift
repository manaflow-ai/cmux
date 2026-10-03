import CmuxNextDaemon
import CmuxNextTabs

// Tab group intents -> daemon tab group commands. The strip
// applies nothing itself; the store echo updates it. Any rejection
// (including a daemon without tab-groups-v1) re-pushes the daemon's
// authoritative membership into the strip. A daemon with state resources
// gets the v2 `tab_group.*` operations (idempotency keys, public ids);
// moves to a split, a column or a new workspace and saved groups have no
// v2 operation and stay on the raw commands.
extension PaneController {
    /// The v2 tab group operations apply (state resources and public ids).
    private var usesStateGroups: Bool { daemon.store.servesStateResources && pane.resourceID != nil }

    func handleGroup(_ intent: TabStripIntent) {
        let handle = pane.handle
        let paneResource = pane.resourceID
        let v2 = usesStateGroups
        switch intent {
        case .toggleGroupCollapsed(let id):
            let group = TabGroupID_(id)
            let collapsed = !(stripModel.group(id)?.isCollapsed ?? false)
            if collapsed, let selected = stripModel.selectedID, stripModel.tab(selected)?.groupID == id,
               let outside = stripModel.orderedTabs.first(where: { $0.groupID != id }) {
                select(outside.id)
            }
            groupCommand("update-tab-group", intent: .setTabGroupCollapsed(group, collapsed: collapsed)) { connection, transaction in
                if v2 { return try await connection.state.updateTabGroup(group.rawValue, collapsed: collapsed) }
                _ = try await connection.updateTabGroup(group, collapsed: collapsed, transaction: transaction)
            }
        case .moveGroup(let id, let to):
            let group = TabGroupID_(id)
            groupCommand("move-tab-group") { connection, transaction in
                if v2 { return try await connection.state.moveTabGroup(group.rawValue, toPane: paneResource, index: to) }
                _ = try await connection.moveTabGroup(group, to: handle, index: to, transaction: transaction)
            }
        case .addToGroup(let tabID, let id, let index):
            guard let tab = tab(tabID) else { return }
            let surface = tab.surface, resource = tab.resourceID
            let group = TabGroupID_(id)
            groupCommand("add-tabs-to-group") { connection, transaction in
                if v2, let resource { return try await connection.state.addTabs([resource], toTabGroup: group.rawValue, index: index) }
                _ = try await connection.addTabs([surface], toGroup: group, index: index, transaction: transaction)
            }
        case .removeFromGroup(let tabID, _):
            guard let tab = tab(tabID) else { return }
            let surface = tab.surface, resource = tab.resourceID
            groupCommand("remove-tabs-from-group") { connection, transaction in
                if v2, let resource { return try await connection.state.removeTabsFromTabGroup([resource]) }
                _ = try await connection.removeTabsFromGroup([surface], transaction: transaction)
            }
        case .createGroup(let item, let tabs):
            let models = tabs.compactMap { tab($0) }
            let surfaces = models.map(\.surface), resources = models.compactMap(\.resourceID)
            let name = item.name, color = item.colorToken.rawValue
            groupCommand("create-tab-group") { connection, transaction in
                if v2, resources.count == surfaces.count, !resources.isEmpty {
                    _ = try await connection.state.createTabGroup(tabs: resources, name: name, color: color)
                    return
                }
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
        let v2 = usesStateGroups, id = group.rawValue
        switch command {
        case .rename(_, let name):
            groupCommand("update-tab-group") { c, t in
                if v2 { return try await c.state.updateTabGroup(id, name: name) }
                _ = try await c.updateTabGroup(group, name: name, transaction: t)
            }
        case .setColor(_, let color):
            groupCommand("update-tab-group") { c, t in
                if v2 { return try await c.state.updateTabGroup(id, color: color.rawValue) }
                _ = try await c.updateTabGroup(group, color: .set(color.rawValue), transaction: t)
            }
        case .newTab(let id):
            let groupTabs = stripModel.orderedTabs.filter { $0.groupID == id }.map(\.id.rawValue)
            StripNewTab.requestInGroup(selected: stripModel.selectedID?.rawValue, groupTabs: groupTabs, pane: paneKey) {
                _ = services.registry.perform($0, invocation: $1)
            }
        case .ungroup:
            groupCommand("ungroup-tab-group") { c, t in
                if v2 { return try await c.state.ungroupTabGroup(id) }
                _ = try await c.ungroupTabGroup(group, transaction: t)
            }
        case .close:
            groupCommand("close-tab-group") { c, t in
                if v2 { return try await c.state.closeTabGroup(id) }
                _ = try await c.closeTabGroup(group, transaction: t)
            }
        case .moveToNewWindow:
            groupCommand("move-tab-group-to-new-workspace") { c, t in _ = try await c.moveTabGroupToNewWorkspace(group, transaction: t) }
        case .save:
            groupCommand("save-tab-group") { c, _ in _ = try await c.saveTabGroup(group) }
        case .unsave:
            let saved = daemon.store.savedTabGroups.first { $0.openGroup == group }?.id
            guard let saved else { return }
            groupCommand("unsave-tab-group") { c, _ in try await c.unsaveTabGroup(saved) }
        }
    }

    /// After a drag moved `tab` into this pane: joins `group` (or leaves its
    /// group when nil) if membership differs. Needs tab-groups-v1.
    func syncGroupMembership(of tab: TabModel, to group: String?) {
        guard tab.tabGroup?.rawValue != group, daemon.supports(DaemonCapabilities.shared.tabGroups) else { return }
        let surface = tab.surface, resource = usesStateGroups ? tab.resourceID : nil
        if let group {
            let id = CmuxNextDaemon.TabGroupID(rawValue: group)
            groupCommand("add-tabs-to-group") { c, t in
                if let resource { return try await c.state.addTabs([resource], toTabGroup: group) }
                _ = try await c.addTabs([surface], toGroup: id, transaction: t)
            }
        } else {
            groupCommand("remove-tabs-from-group") { c, t in
                if let resource { return try await c.state.removeTabsFromTabGroup([resource]) }
                _ = try await c.removeTabsFromGroup([surface], transaction: t)
            }
        }
    }

    /// Sends a group command with a fresh transaction, shown at once
    /// through the store's intent log when it has an `intent`.
    private func groupCommand(_ label: String, intent: Intent? = nil,
                              _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        Task {
            let ok = await daemon.runGroupCommand(label, intent: intent, body)
            if !ok { resyncStrip() }
        }
    }
}

/// Daemon tab group id from the strip's id.
private func TabGroupID_(_ id: CmuxNextTabs.TabGroupID) -> CmuxNextDaemon.TabGroupID {
    CmuxNextDaemon.TabGroupID(rawValue: id.rawValue)
}
