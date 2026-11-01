import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextCompat
import CmuxNextSidebar

/// Workspace names, colors, notifications, and Finder reveal (identifier copies: `TabHandlers.bindIdentifiers`).
/// Colors go through the sidebar bridge (optimistic row update, then
/// `set-workspace-metadata`), the same path as the row's context menu.
/// Pin goes through the one pin path (`PinCommands`).
/// Description and task status are `WorkspaceNotesHandlers`; the checklist is
/// `WorkspaceChecklistHandlers`.
enum WorkspaceMetadataHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.clearWorkspaceName", requires: DaemonCapability.workspaceMetadata.rawValue, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapability.workspaceMetadata.rawValue)
            let key = try context.workspace(invocation).key
            let daemon = context.services.activeDaemon, resource = daemon.store.stateResourceID(workspace: key)
            daemon.send("set-workspace-metadata") { try await $0.state.setWorkspaceIdentity(key, resource: resource, title: .clear) }
        })
        registry.bind("palette.workspaceColor", requires: DaemonCapability.workspaceMetadata.rawValue, daemon: context.services.activeDaemon, run: { invocation in
            guard let raw = invocation["color"]?.stringValue, let color = GroupColor(rawValue: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf(GroupColor.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            try setColor(color, invocation, context)
        })
        // One pin path (PinCommands): a layout tile once the store serves the
        // layout, else the legacy flag, which then needs `workspace-pin-v1`.
        registry.bind("palette.toggleWorkspacePin", requires: DaemonCapability.workspacePin.rawValue, daemon: {
            PinCommands(context: context).pinsAreTiles ? nil : context.services.activeDaemon
        }(), run: { invocation in
            // Every selected row takes the right-clicked row's new state (Finder's tags), else `pinned` (CLI, MCP) sets it.
            let commands = PinCommands(context: context)
            let pinned = try invocation["pinned"]?.boolValue ?? !commands.isWorkspacePinned(context.workspace(invocation).model)
            try commands.setWorkspacesPinned(WindowMembershipHandlers.rowTargets(invocation, context).map(\.id), pinned: pinned, origin: invocation.origin)
        })
        // The workspace menu reads Pin Workspace or Unpin Workspace for the right-clicked row.
        ActionTargetTitles.set("palette.toggleWorkspacePin", in: registry) { invocation in
            guard let workspace = try? context.workspace(invocation).model else { return nil }
            return PinCommands(context: context).isWorkspacePinned(workspace) ? PinStrings.unpinWorkspace : PinStrings.pinWorkspace
        }
        // Add to Top / Remove from Top on the workspace row (P1): the same layout path as `sidebar.item.add`.
        registry.bind("workspace.toggleTop", unavailable: { SidebarDocWiring.layoutUnavailableReason(context.services.sidebarLayout) }, run: { invocation in
            try PinCommands(context: context).toggleWorkspaceOnTop(try context.workspace(invocation).model.id, origin: invocation.origin)
        })
        ActionTargetTitles.set("workspace.toggleTop", in: registry) { invocation in
            guard let workspace = try? context.workspace(invocation).model else { return nil }
            return PinCommands(context: context).isWorkspaceOnTopRows(workspace.id) ? PinStrings.removeFromTop : PinStrings.addToTop
        }
        registry.bind("palette.resetWorkspaceColor", requires: DaemonCapability.workspaceMetadata.rawValue, daemon: context.services.activeDaemon, run: { invocation in try setColor(nil, invocation, context) })
        registry.bind("workspace.removeAllColors", requires: DaemonCapability.workspaceMetadata.rawValue, daemon: context.services.activeDaemon, run: { _ in
            try removeAllColors(context)
        })
        for id: ActionID in ["palette.markWorkspaceRead", "clearWorkspaceNotifications"] {
            registry.bind(id, requires: DaemonCapability.notificationAck.rawValue, daemon: context.services.activeDaemon, run: { invocation in
                try acknowledge([try context.workspace(invocation).model], context)
            })
        }
        registry.bind("revealWorkspaceInFinder", run: { invocation in
            let workspace = try context.workspace(invocation).model
            guard let cwd = directory(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceHasNoDirectory) }
            NSWorkspace.shared.revealInBackground([URL(fileURLWithPath: cwd)])
        })

        registry.bind("palette.markWorkspaceUnread", requires: DaemonCapability.notificationMarkUnread.rawValue, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapability.notificationMarkUnread.rawValue)
            WorkspaceUnreadMark.set(true, on: [try context.workspace(invocation).model], machines: context.services.machines)
        })
    }

    private static func setColor(_ color: GroupColor?, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        try context.require(DaemonCapability.workspaceMetadata.rawValue)
        let (workspace, key) = try context.workspace(invocation)
        if let sidebar = context.activeWindow?.sidebar {
            // A person's swatch on one of several selected rows colors them all (the selection menu's header).
            sidebar.handle(.setColor(try WindowMembershipHandlers.rowTargets(invocation, context).map { SidebarWorkspaceID($0.id) }, color))
        } else {
            let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
            let daemon = context.services.activeDaemon, resource = daemon.store.stateResourceID(workspace: key)
            // The same store intent as the sidebar's path (#25657): shown now, rolled back on a refusal.
            let send = daemon.intendNow("set-workspace-metadata", .setWorkspaceColor(key: key, color: color?.rawValue), transaction: .generate()) {
                try await $0.state.setWorkspaceIdentity(key, resource: resource, color: update)
            }
            // task-owner: one metadata command; the store intent settles or rolls back on its reply
            Task { _ = await send() }
        }
    }

    /// Remove All Workspace Colors (Lawrence 2026-10-22: "need to be able to remove all workspace
    /// colors"): every workspace on every machine loses its color, and every group the window lists
    /// takes no color (`none`), each through the same path as its own menu's No Color swatch.
    private static func removeAllColors(_ context: AppActionContext) throws {
        try context.require(DaemonCapability.workspaceMetadata.rawValue)
        let sidebar = try context.sidebar()
        let colored = context.services.machines.daemons.flatMap { daemon in daemon.store.workspaces.filter { $0.color != nil }.map(\.id) }
        if !colored.isEmpty { sidebar.handle(.setColor(colored.map(SidebarWorkspaceID.init), nil)) }
        for group in sidebar.model.coloredGroups { sidebar.handle(.setGroupColor(group, GroupTint.none)) }
    }

    /// Acknowledges every unread tab of `workspaces` (all tabs when the
    /// daemon rollup reports unread but no tab carries a marker).
    static func acknowledge(_ workspaces: [WorkspaceModel], _ context: AppActionContext) throws {
        try context.require(DaemonCapability.notificationAck.rawValue)
        let machines = context.services.machines
        WorkspaceUnreadMark.set(false, on: workspaces, machines: machines)
        // A group's members can live on different machines.
        for (workspace, daemon) in WorkspaceUnreadMark.routes(workspaces, machines: machines)
        where daemon.supports(DaemonCapability.notificationAck.rawValue) {
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            let unread = tabs.filter(\.hasUnread)
            for tab in unread.isEmpty && workspace.unreadCount > 0 ? tabs : unread {
                let surface = tab.surface
                // Read now (dots, badges, unread count); the tree's echo settles it, a failed ack rolls it back.
                tab.expectNotificationRead()
                daemon.send("ack-tab-notifications", onFailure: { _ in tab.dropExpectedNotificationRead() }) {
                    _ = try await $0.acknowledgeNotifications(of: surface)
                }
            }
        }
    }

    /// Working directory of the focused tab when the workspace is shown,
    /// else of its first tab that reports one.
    private static func directory(of workspace: WorkspaceModel, _ context: AppActionContext) -> String? {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        if context.activeWindow?.state.workspaceID == workspace.id,
           let pane = context.activeWindow?.focusedPane, let id = pane.stripModel.selectedID,
           let cwd = tabs.first(where: { $0.id == id.rawValue })?.cwd {
            return cwd
        }
        return tabs.lazy.compactMap(\.cwd).first
    }
}
