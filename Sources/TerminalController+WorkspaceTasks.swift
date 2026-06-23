import Foundation

extension TerminalController {
    nonisolated func v2WorkspaceTasksList(params: [String: Any]) -> V2CallResult {
        v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager))
        }
    }

    nonisolated func v2WorkspaceTasksAdd(params: [String: Any]) -> V2CallResult {
        guard let title = v2String(params, "title") ?? v2String(params, "text") else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.workspaceTasks.add.missingTitle", defaultValue: "workspace.tasks.add requires title"),
                data: nil
            )
        }
        guard !WorkspaceTask.normalizedTitle(title).isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.workspaceTasks.add.emptyTitle", defaultValue: "Task title cannot be empty"),
                data: nil
            )
        }
        let beforeTaskId = v2UUID(params, "before_task_id") ?? v2UUID(params, "before_id")
        let afterTaskId = v2UUID(params, "after_task_id") ?? v2UUID(params, "after_id")
        let index = v2Int(params, "index")
        return v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            guard let task = workspace.addWorkspaceTask(title: title, before: beforeTaskId, after: afterTaskId, index: index) else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.workspaceTasks.add.anchorNotFound", defaultValue: "Task insertion anchor not found"),
                    data: v2WorkspaceTasksAnchorErrorData(beforeTaskId: beforeTaskId, afterTaskId: afterTaskId)
                )
            }
            return .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager, changedTask: task))
        }
    }

    nonisolated func v2WorkspaceTasksArchive(params: [String: Any]) -> V2CallResult {
        guard let taskId = v2UUID(params, "task_id") ?? v2UUID(params, "id") else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.workspaceTasks.taskIdRequired", defaultValue: "workspace task command requires task_id"),
                data: nil
            )
        }
        return v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            guard let task = workspace.archiveWorkspaceTask(id: taskId) else {
                return .err(code: "not_found", message: String(localized: "socket.workspaceTasks.notFound", defaultValue: "Task not found"), data: ["task_id": taskId.uuidString])
            }
            return .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager, changedTask: task))
        }
    }

    nonisolated func v2WorkspaceTasksRemove(params: [String: Any]) -> V2CallResult {
        guard let taskId = v2UUID(params, "task_id") ?? v2UUID(params, "id") else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.workspaceTasks.taskIdRequired", defaultValue: "workspace task command requires task_id"),
                data: nil
            )
        }
        return v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            guard let task = workspace.removeWorkspaceTask(id: taskId) else {
                return .err(code: "not_found", message: String(localized: "socket.workspaceTasks.notFound", defaultValue: "Task not found"), data: ["task_id": taskId.uuidString])
            }
            return .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager, changedTask: task))
        }
    }

    nonisolated func v2WorkspaceTasksMove(params: [String: Any]) -> V2CallResult {
        guard let taskId = v2UUID(params, "task_id") ?? v2UUID(params, "id") else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.workspaceTasks.taskIdRequired", defaultValue: "workspace task command requires task_id"),
                data: nil
            )
        }
        let beforeTaskId = v2UUID(params, "before_task_id") ?? v2UUID(params, "before_id")
        let afterTaskId = v2UUID(params, "after_task_id") ?? v2UUID(params, "after_id")
        let index = v2Int(params, "index")
        return v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            guard let task = workspace.moveWorkspaceTask(id: taskId, before: beforeTaskId, after: afterTaskId, index: index) else {
                return .err(code: "not_found", message: String(localized: "socket.workspaceTasks.notFound", defaultValue: "Task not found"), data: ["task_id": taskId.uuidString])
            }
            return .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager, changedTask: task))
        }
    }

    nonisolated func v2WorkspaceTasksOpen(params: [String: Any]) -> V2CallResult {
        let requestedFocus = v2Bool(params, "focus") ?? false
        return v2WorkspaceTasksCommand(params: params) { workspace, tabManager in
            let focus = v2FocusAllowed(requested: requestedFocus)
            guard let panel = workspace.openOrFocusWorkspaceTasksSurface(focus: focus) else {
                return .err(
                    code: "unavailable",
                    message: String(localized: "socket.workspaceTasks.openFailed", defaultValue: "Workspace Tasks surface could not be opened"),
                    data: nil
                )
            }
            return .ok(v2WorkspaceTasksPayload(workspace: workspace, tabManager: tabManager, changedSurfaceId: panel.id))
        }
    }

    nonisolated private func v2WorkspaceTasksCommand(
        params: [String: Any],
        body: @MainActor (_ workspace: Workspace, _ tabManager: TabManager) -> V2CallResult
    ) -> V2CallResult {
        for key in ["workspace_id", "surface_id", "terminal_id", "tab_id", "pane_id", "window_id"] {
            if v2HasNonNullParam(params, key), v2UUID(params, key) == nil {
                return .err(
                    code: "invalid_params",
                    message: String(
                        format: String(
                            localized: "socket.workspaceTasks.unresolvedIdentifier",
                            defaultValue: "Unresolved %@"
                        ),
                        locale: .current,
                        key
                    ),
                    data: nil
                )
            }
        }
        return v2MainSync { () -> V2CallResult in
            guard Workspace.workspaceTasksBetaEnabled() else {
                return .err(
                    code: "disabled",
                    message: String(localized: "socket.workspaceTasks.disabled", defaultValue: "Workspace Tasks beta is disabled"),
                    data: nil
                )
            }
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(
                    code: "unavailable",
                    message: String(
                        localized: "socket.workspaceTasks.tabManagerUnavailable",
                        defaultValue: "TabManager not available"
                    ),
                    data: nil
                )
            }
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: String(localized: "socket.workspaceTasks.workspaceNotFound", defaultValue: "Workspace not found"), data: nil)
            }
            return body(workspace, tabManager)
        }
    }

    @MainActor
    private func v2WorkspaceTasksPayload(
        workspace: Workspace,
        tabManager: TabManager,
        changedTask: WorkspaceTask? = nil,
        changedSurfaceId: UUID? = nil
    ) -> [String: Any] {
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": workspace.id.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "tasks": workspace.workspaceTasks.map(v2WorkspaceTaskPayload),
            "open": workspace.openWorkspaceTasks.map(v2WorkspaceTaskPayload),
            "archived": workspace.archivedWorkspaceTasks.map(v2WorkspaceTaskPayload),
            "open_count": workspace.openWorkspaceTasks.count,
            "archived_count": workspace.archivedWorkspaceTasks.count
        ]
        if let changedTask {
            payload["task"] = v2WorkspaceTaskPayload(changedTask)
        }
        if let changedSurfaceId {
            payload["surface_id"] = changedSurfaceId.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: changedSurfaceId)
        }
        return payload
    }

    private nonisolated func v2WorkspaceTaskPayload(_ task: WorkspaceTask) -> [String: Any] {
        [
            "id": task.id.uuidString,
            "title": task.title,
            "status": task.isArchived ? "archived" : "open",
            "created_at": Self.workspaceTaskDateString(task.createdAt),
            "archived_at": task.archivedAt.map(Self.workspaceTaskDateString(_:)) ?? NSNull()
        ]
    }

    private nonisolated static func workspaceTaskDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private nonisolated func v2WorkspaceTasksAnchorErrorData(
        beforeTaskId: UUID?,
        afterTaskId: UUID?
    ) -> [String: Any]? {
        if let beforeTaskId {
            return ["before_task_id": beforeTaskId.uuidString]
        }
        if let afterTaskId {
            return ["after_task_id": afterTaskId.uuidString]
        }
        return nil
    }
}
