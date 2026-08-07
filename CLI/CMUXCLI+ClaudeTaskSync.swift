import CMUXAgentLaunch
import CryptoKit
import Darwin
import Foundation

extension CMUXCLI {
    /// Reconciles Claude Code's per-file task store into cmux's two todo views.
    ///
    /// A full filesystem snapshot is published to both Feed and the workspace
    /// checklist so neither consumer has to reimplement TaskCreate/TaskUpdate
    /// accumulation semantics.
    func runClaudeTaskSyncHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        socketPassword: String?,
        markFeedTelemetryHandled: () -> Void
    ) {
        telemetry.breadcrumb("claude-hook.task-sync")
        markFeedTelemetryHandled()

        guard let sessionID = nonEmptyClaudeHookIdentifier(parsedInput.sessionId) else {
            telemetry.breadcrumb("claude-hook.task-sync.missing-session")
            printClaudeHookAck()
            return
        }

        do {
            let mappedSession = try? sessionStore.lookup(sessionId: sessionID)
            var taskRouting = routing
            taskRouting.allowsPidProbe = false
            guard let resolvedTarget = try resolveClaudeHookDeliveryTarget(
                mappedSession: mappedSession,
                routing: taskRouting,
                client: client
            ) else {
                telemetry.breadcrumb("claude-hook.task-sync.unresolved")
                printClaudeHookAck()
                return
            }

            let environment = ProcessInfo.processInfo.environment
            let configuredTaskListID = environment["CLAUDE_CODE_TASK_LIST_ID"].flatMap {
                $0.isEmpty ? nil : $0
            }
            // Configured task lists are list-scoped, not session-scoped: a
            // leader and its teammates have different session IDs, and every
            // hook rereads the same authoritative directory under the lock.
            // Session-owned task directories retain the active-session guard.
            guard configuredTaskListID != nil || shouldApplyClaudeHookVisibleMutation(
                sessionStore: sessionStore,
                parsedInput: parsedInput,
                workspaceId: resolvedTarget.workspaceId,
                surfaceId: resolvedTarget.isAuthoritative ? resolvedTarget.surfaceId : nil,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("claude-hook.task-sync.stale")
                printClaudeHookAck()
                return
            }

            // Nested teammates mutate the same authoritative task list. Their
            // task hooks must publish it even though other visible mutations
            // stay suppressed; live routing was already validated above, while
            // the resolved list identity owns shared synchronization.
            let tasksRootURL = ClaudeTaskRootResolver(
                environment: environment,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            ).resolve()
            let loader = ClaudeTaskSnapshotLoader(tasksRootURL: tasksRootURL)
            // Claude starts async hooks as independent CLI processes, which a
            // Swift actor cannot serialize. This filesystem lock is therefore
            // scoped to the one read-and-publish transaction: a later hook reads
            // the latest files only after the earlier snapshot finishes delivery.
            try withClaudeTaskSnapshotLock(loader: loader) {
                let currentRecord = try sessionStore.lookup(sessionId: sessionID)
                let snapshot: ClaudeTaskSnapshot?
                if let taskListID = configuredTaskListID {
                    snapshot = try loader.loadConfiguredTaskList(taskListID: taskListID)
                } else {
                    snapshot = try loader.load(
                        sessionID: sessionID,
                        boundDirectoryName: currentRecord?.claudeTaskDirectoryName,
                        taskIdentity: claudeTaskIdentity(from: parsedInput.rawObject)
                    )
                }
                guard let snapshot else {
                    telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
                    return
                }
                guard let checklistOwnerID = claudeTaskChecklistOwnerID(
                    taskDirectoryName: snapshot.directoryName
                ) else {
                    telemetry.breadcrumb("claude-hook.task-sync.invalid-checklist-owner")
                    return
                }
                try sessionStore.bindClaudeTaskDirectory(
                    sessionId: sessionID,
                    directoryName: snapshot.directoryName,
                    workspaceId: resolvedTarget.workspaceId,
                    surfaceId: resolvedTarget.surfaceId
                )
                let todos = snapshot.todos
                let feedSnapshot: [String: Any] = [
                    "todos": todos.map(claudeTaskFeedDictionary),
                ]
                sendFeedTelemetry(
                    client: client,
                    source: "claude",
                    subcommand: "task-sync",
                    parsedInput: parsedInput,
                    workspaceId: resolvedTarget.workspaceId,
                    surfaceId: resolvedTarget.surfaceId,
                    socketPassword: socketPassword,
                    toolNameOverride: "TodoWrite",
                    toolInputOverride: feedSnapshot
                )

                let checklistItems = todos.map {
                    claudeTaskChecklistDictionary(
                        $0,
                        taskDirectoryName: snapshot.directoryName
                    )
                }
                do {
                    _ = try client.sendV2(
                        method: "workspace.todo.reconcile",
                        params: [
                            "workspace_id": resolvedTarget.workspaceId,
                            "owner_id": checklistOwnerID,
                            "items": checklistItems,
                        ]
                    )
                } catch {
                    telemetry.breadcrumb(
                        "claude-hook.task-sync.workspace-error",
                        data: ["error": String(describing: error)]
                    )
                }
            }
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.error",
                data: ["error": String(describing: error)]
            )
        }
        printClaudeHookAck()
    }

    private func withClaudeTaskSnapshotLock(
        loader: ClaudeTaskSnapshotLoader,
        body: () throws -> Void
    ) throws {
        try FileManager.default.createDirectory(
            at: loader.tasksRootURL,
            withIntermediateDirectories: true
        )
        let lockURL = loader.tasksRootURL.appendingPathComponent(".cmux-task-sync.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        try body()
    }

    /// Extracts the exact task identity from Claude's uncompacted hook payload.
    ///
    /// The compact Feed payload intentionally omits `tool_response`, so task
    /// directory resolution must read the original object retained by the hook
    /// parser. A partial identity is never used for directory selection.
    private func claudeTaskIdentity(from rawObject: [String: Any]?) -> ClaudeTaskIdentity? {
        let input = rawObject?["tool_input"] as? [String: Any]
        // A successful delete removes the identity-bearing task file before
        // PostToolUse runs. Reuse an existing proven binding (or the exact
        // session path) instead of treating that expected absence as a failed
        // ownership proof.
        if input?["status"] as? String == "deleted" {
            return nil
        }
        guard let response = rawObject?["tool_response"] as? [String: Any],
              let task = response["task"] as? [String: Any],
              let id = task["id"] as? String,
              !id.isEmpty else { return nil }
        let responseSubject = task["subject"] as? String
        let inputSubject = input?["subject"] as? String
        guard let subject = responseSubject ?? inputSubject,
              !subject.isEmpty else { return nil }
        return ClaudeTaskIdentity(id: id, subject: subject)
    }

    private func claudeTaskFeedDictionary(_ todo: WorkstreamTaskTodo) -> [String: Any] {
        var value: [String: Any] = [
            "id": todo.id,
            "content": todo.content,
            "status": claudeTaskState(todo.state, workspaceWireFormat: false),
        ]
        if let activeForm = todo.activeForm {
            value["activeForm"] = activeForm
        }
        return value
    }

    private func claudeTaskChecklistDictionary(
        _ todo: WorkstreamTaskTodo,
        taskDirectoryName: String
    ) -> [String: Any] {
        [
            "id": claudeTaskChecklistID(
                taskDirectoryName: taskDirectoryName,
                taskID: todo.id
            ).uuidString,
            "text": todo.displayContent,
            "state": claudeTaskState(todo.state, workspaceWireFormat: true),
            "origin": "agent",
        ]
    }

    private func claudeTaskChecklistOwnerID(taskDirectoryName: String) -> String? {
        let ownerID = "claude:\(taskDirectoryName)"
        return ownerID.count <= 500 ? ownerID : nil
    }

    private func claudeTaskState(
        _ state: WorkstreamTaskTodo.State,
        workspaceWireFormat: Bool
    ) -> String {
        switch state {
        case .pending: return "pending"
        case .inProgress: return workspaceWireFormat ? "in-progress" : "in_progress"
        case .completed: return "completed"
        }
    }

    private func claudeTaskChecklistID(taskDirectoryName: String, taskID: String) -> UUID {
        let name = "cmux.claude-task\0\(taskDirectoryName)\0\(taskID)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
