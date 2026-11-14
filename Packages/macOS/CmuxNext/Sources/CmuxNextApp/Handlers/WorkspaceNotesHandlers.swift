import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWindowRules

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
            try send(.describe(invocation["description"]?.stringValue), invocation, context)
        })
        registry.bind("palette.clearWorkspaceDescription", requires: description, daemon: context.services.activeDaemon, run: { invocation in
            try send(.clearDescription, invocation, context)
        })
        registry.bind("markWorkspaceDone", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            try send(.markDone, invocation, context)
        })
        registry.bind("cycleWorkspaceStatus", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            try send(.cycleStatus(current: context.workspace(invocation).model.taskStatus?.rawValue), invocation, context)
        })
        registry.bind("palette.workspaceStatus", requires: status, daemon: context.services.activeDaemon, run: { invocation in
            try send(.setStatus(invocation["status"]?.stringValue), invocation, context)
        })
    }

    /// Sends the write of `verb` (cmux-window-rules `workspaces::notes`: the trimmed description,
    /// the status lane, the capabilities its fields need) for the invocation's workspace to the
    /// daemon that holds it, after checking that daemon serves each field it changes.
    static func send(_ verb: WindowRules.NotesVerb, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let update: WindowRules.NotesUpdate
        switch WindowRules().notes(verb) {
        case .success(let made)?: update = made
        case .failure(let refused)?: throw ActionFailure.invalidTarget(RefusalStrings.statusMustBeOneOf(refused.choices.joined(separator: ", ")))
        case nil: throw ActionFailure(message: RefusalStrings.describe(WindowRules.Unanswered(operation: "window_workspace_notes")))
        }
        let (workspace, key) = try context.workspace(invocation)
        let daemon = context.services.machines.workspace(id: workspace.id)?.1 ?? context.services.activeDaemon
        for capability in update.capabilities where !daemon.supports(capability) {
            throw ActionFailure(message: daemon.missingCapabilityMessage(capability))
        }
        guard let resource = daemon.store.stateResourceID(workspace: key) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.stateResources.rawValue))
        }
        let description: FieldUpdate<String> = field(update.description) { $0 }
        let taskStatus: FieldUpdate<WorkspaceTaskStatus> = field(update.taskStatus) { WorkspaceTaskStatus(rawValue: $0) }
        daemon.send("workspace.update") { connection in
            try await connection.state.updateWorkspace(resource, description: description, taskStatus: taskStatus)
        }
    }

    private static func field<Value: Encodable & Sendable & Hashable>(_ change: WindowRules.FieldChange, _ value: (String) -> Value?) -> FieldUpdate<Value> {
        switch change {
        case .unchanged: .unchanged
        case .clear: .clear
        case .set(let raw): value(raw).map { .set($0) } ?? .unchanged
        }
    }
}
