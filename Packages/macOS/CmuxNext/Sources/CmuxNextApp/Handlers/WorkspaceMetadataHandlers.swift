import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// Workspace names, colors, notifications, identifiers, and Finder reveal.
/// Colors go through the sidebar bridge (optimistic row update, then
/// `set-workspace-metadata`), the same path as the row's context menu.
/// Pin goes through the sidebar bridge the same way (`workspace-pin-v1`).
/// Fields the daemon tree does not have (description, status, checklist)
/// report the missing daemon capability.
enum WorkspaceMetadataHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.clearWorkspaceName", requires: DaemonCapabilities.shared.workspaceMetadata, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.workspaceMetadata)
            let key = try context.workspace(invocation).key
            let daemon = context.services.activeDaemon, resource = daemon.store.stateResourceID(workspace: key)
            daemon.send("set-workspace-metadata") { try await $0.state.setWorkspaceIdentity(key, resource: resource, title: .clear) }
        })
        registry.bind("palette.workspaceColor", requires: DaemonCapabilities.shared.workspaceMetadata, daemon: context.services.activeDaemon, run: { invocation in
            guard let raw = invocation["color"]?.stringValue, let color = GroupColor(rawValue: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf(GroupColor.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            try setColor(color, invocation, context)
        })
        registry.bind("palette.toggleWorkspacePin", requires: DaemonCapabilities.shared.workspacePin, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.workspacePin)
            let (workspace, key) = try context.workspace(invocation)
            let pinned = !workspace.pinned
            if let sidebar = context.activeWindow?.sidebar {
                sidebar.handle(.setPinned([SidebarWorkspaceID(workspace.id)], pinned))
            } else {
                context.services.activeDaemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, pinned: pinned) }
            }
        })
        registry.bind("palette.resetWorkspaceColor", requires: DaemonCapabilities.shared.workspaceMetadata, daemon: context.services.activeDaemon, run: { invocation in try setColor(nil, invocation, context) })
        for id: ActionID in ["palette.markWorkspaceRead", "clearWorkspaceNotifications"] {
            registry.bind(id, requires: DaemonCapabilities.shared.notificationAck, daemon: context.services.activeDaemon, run: { invocation in
                try acknowledge([try context.workspace(invocation).model], context)
            })
        }
        registry.bind("revealWorkspaceInFinder", run: { invocation in
            let workspace = try context.workspace(invocation).model
            guard let cwd = directory(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceHasNoDirectory) }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
        })
        registry.bind("palette.copyWorkspaceID", run: { invocation in context.copy(try context.workspace(invocation).key.rawValue) })
        registry.bind("palette.copyWorkspaceIDAndRef", run: { invocation in
            let key = try context.workspace(invocation).key.rawValue
            context.copy("\(key)\n\(ActionTargetRef(kind: .workspace, id: key))")
        })

        registry.bindUnavailable(["palette.copyWorkspaceLink"], ActionFailure.needsAppCapability("deep-links"))
        registry.bindUnavailable(["palette.workspaceCustomColor"], ActionFailure.needsAppCapability("custom-workspace-colors"))
        registry.bind("palette.markWorkspaceUnread", requires: DaemonCapabilities.shared.notificationMarkUnread, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.notificationMarkUnread)
            WorkspaceUnreadMark.set(true, on: [try context.workspace(invocation).model], machines: context.services.machines)
        })
        let missing: [(ActionID, String)] = [
            ("editWorkspaceDescription", "workspace-description-v1"),
            ("palette.clearWorkspaceDescription", "workspace-description-v1"),
            ("markWorkspaceDone", "workspace-status-v1"),
            ("cycleWorkspaceStatus", "workspace-status-v1"),
            ("palette.workspaceStatus", "workspace-status-v1"),
            ("palette.addWorkspaceChecklistItem", "workspace-checklist-v1"),
            ("toggleChecklistItemComplete", "workspace-checklist-v1"),
            ("palette.openWorkspaceTodoPane", "workspace-checklist-v1"),
        ]
        for (id, capability) in missing {
            registry.bindUnavailable([id], ActionFailure.needsDaemonCapability(capability))
        }
    }

    private static func setColor(_ color: GroupColor?, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        try context.require(DaemonCapabilities.shared.workspaceMetadata)
        let (workspace, key) = try context.workspace(invocation)
        if let sidebar = context.activeWindow?.sidebar {
            sidebar.handle(.setColor([SidebarWorkspaceID(workspace.id)], color))
        } else {
            let update: FieldUpdate<String> = color.map { .set($0.rawValue) } ?? .clear
            let daemon = context.services.activeDaemon, resource = daemon.store.stateResourceID(workspace: key)
            daemon.send("set-workspace-metadata") { try await $0.state.setWorkspaceIdentity(key, resource: resource, color: update) }
        }
    }

    /// Acknowledges every unread tab of `workspaces` (all tabs when the
    /// daemon rollup reports unread but no tab carries a marker).
    static func acknowledge(_ workspaces: [WorkspaceModel], _ context: AppActionContext) throws {
        try context.require(DaemonCapabilities.shared.notificationAck)
        let machines = context.services.machines
        WorkspaceUnreadMark.set(false, on: workspaces, machines: machines)
        // A group's members can live on different machines.
        for (workspace, daemon) in WorkspaceUnreadMark.routes(workspaces, machines: machines)
        where daemon.supports(DaemonCapabilities.shared.notificationAck) {
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            let unread = tabs.filter(\.hasUnread)
            let surfaces = (unread.isEmpty && workspace.unreadCount > 0 ? tabs : unread).map(\.surface)
            for surface in surfaces {
                daemon.send("ack-tab-notifications") { _ = try await $0.acknowledgeNotifications(of: surface) }
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
