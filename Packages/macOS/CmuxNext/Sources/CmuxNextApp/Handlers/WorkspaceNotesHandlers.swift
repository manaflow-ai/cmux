import CmuxNextActions
import CmuxNextDaemon

/// A workspace's description (`workspace-description-v1`) and its manual
/// task status (`workspace-status-v1`, classic cmux's lanes). Every
/// entrypoint (palette, workspace row menu, keyboard, `cmux workspace
/// edit-description|clear-description|mark-as-done|cycle-status|set-status`,
/// MCP) runs one of these actions, and each writes through `send`: one
/// `workspace.update` to the daemon that owns the workspace. The sidebar row
/// and hover card follow the daemon's echo.
enum WorkspaceNotesHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let description = DaemonCapability.workspaceDescription.rawValue
        let status = DaemonCapability.workspaceStatus.rawValue
        // The palette, menu and shortcut ask for the text first (the argument is required).
        registry.bind("editWorkspaceDescription", requires: description, daemon: context.services.activeDaemon, run: { invocation in
            let text = invocation["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try send(WorkspaceNotesUpdate(description: text.isEmpty ? .clear : .set(text)), invocation, context)
        })
        registry.bind("palette.clearWorkspaceDescription", requires: description, daemon: context.services.activeDaemon, run: { invocation in
            try send(WorkspaceNotesUpdate(description: .clear), invocation, context)
        })
        registry.bind("markWorkspaceDone", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            try send(WorkspaceNotesUpdate(taskStatus: .set(.done)), invocation, context)
        })
        registry.bind("cycleWorkspaceStatus", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            let current = try context.workspace(invocation).model.taskStatus
            try send(WorkspaceNotesUpdate(taskStatus: .set(WorkspaceNotesUpdate.cycled(current))), invocation, context)
        })
        registry.bind("palette.workspaceStatus", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            guard let update = WorkspaceNotesUpdate(statusChoice: invocation["status"]?.stringValue ?? "") else {
                throw ActionFailure.invalidTarget(RefusalStrings.statusMustBeOneOf(WorkspaceNotesUpdate.statusChoices.joined(separator: ", ")))
            }
            try send(update, invocation, context)
        })
    }

    /// Sends `update` for the invocation's workspace to the daemon that holds
    /// it, after checking that daemon serves each field it changes.
    static func send(_ update: WorkspaceNotesUpdate, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let (workspace, key) = try context.workspace(invocation)
        let daemon = context.services.machines.workspace(id: workspace.id)?.1 ?? context.services.activeDaemon
        for capability in update.capabilities where !daemon.supports(capability) {
            throw ActionFailure(message: daemon.missingCapabilityMessage(capability))
        }
        guard let resource = daemon.store.stateResourceID(workspace: key) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.stateResources.rawValue))
        }
        daemon.send("workspace.update") { connection in
            try await connection.state.updateWorkspace(resource, description: update.description, taskStatus: update.taskStatus)
        }
    }
}
