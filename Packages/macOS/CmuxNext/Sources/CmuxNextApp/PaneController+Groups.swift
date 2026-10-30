import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
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
    var usesStateGroups: Bool { daemon.store.servesStateResources && pane.resourceID != nil }

    func handleGroup(_ intent: TabStripIntent) {
        let handle = pane.handle
        let paneResource = pane.resourceID
        let v2 = usesStateGroups
        switch intent {
        case .toggleGroupCollapsed(let id):
            let group = TabGroupID_(id)
            let collapsed = !(stripModel.group(id)?.isCollapsed ?? false)
            // The nearest tab still shown, as the menu's Collapse picks it: the first tab outside the
            // group could sit in another collapsed group, selected but not drawn.
            if collapsed, let next = TabGroupOrdering.selectionBeforeCollapsing(
                id, in: stripModel.orderedTabs, collapsed: Set(stripModel.groups.filter(\.isCollapsed).map(\.id)),
                selected: stripModel.selectedID) {
                select(next)
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
            let index = index.map { StripOrder.groupIndex($0, moving: tabID, group: id, in: self) }
            groupCommand("add-tabs-to-group", groupWrites.add([tab], to: TabGroupID_(id), index: index))
        case .removeFromGroup(let tabID, _):
            guard let tab = tab(tabID) else { return }
            groupCommand("remove-tabs-from-group", groupWrites.remove([tab]))
        case .createGroup(let item, let tabs):
            // Writes stay on the token path until the daemon takes `#RRGGBB` for tab groups (cx-wqn5).
            groupCommand("create-tab-group", groupWrites.create(tabs.compactMap { tab($0) }, name: item.name, color: item.colorToken.rawValue))
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
        case .setColor(_, let tint):
            groupCommand("update-tab-group") { c, t in
                if v2 { return try await c.state.updateTabGroup(id, color: tint.wire) }
                _ = try await c.updateTabGroup(group, color: .set(tint.wire), transaction: t)
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
            // The menu's Move Group to New Window: the action places the moved
            // workspace (the raw daemon move left it at the daemon's place, cx-caoh).
            services.registry.perform("tabGroup.moveToNewWindow", invocation: ActionInvocation(target: ActionTargetRef(kind: .tabGroup, id: id)))
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
        guard tab.tabGroup?.rawValue != group, daemon.supports(DaemonCapability.tabGroups.rawValue) else { return }
        if let group {
            groupCommand("add-tabs-to-group", groupWrites.add([tab], to: CmuxNextDaemon.TabGroupID(rawValue: group)))
        } else {
            groupCommand("remove-tabs-from-group", groupWrites.remove([tab]))
        }
    }

    /// Sends a group command with a fresh transaction, shown at once
    /// through the store's intent log when it has an `intent`.
    /// This pane's group membership writes (`TabGroupWrites`), shared with the tab group actions.
    var groupWrites: TabGroupWrites { TabGroupWrites(pane: pane, daemon: daemon) }

    func groupCommand(_ label: String, intent: Intent? = nil,
                      _ body: @escaping @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void) {
        Task {
            let ok = await daemon.runGroupCommand(label, intent: intent, body)
            if ok { StripOrder.settle([self]) } else { resyncStrip() } // one ordering source (R38)
        }
    }
}

/// Daemon tab group id from the strip's id.
func TabGroupID_(_ id: CmuxNextTabs.TabGroupID) -> CmuxNextDaemon.TabGroupID {
    CmuxNextDaemon.TabGroupID(rawValue: id.rawValue)
}
