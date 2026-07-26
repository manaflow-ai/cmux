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

            guard shouldApplyClaudeHookVisibleMutation(
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

            let claudePID = mappedSession?.pid
                ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
            guard !shouldSuppressNestedAgentVisibleMutations(
                currentAgentPID: claudePID,
                env: ProcessInfo.processInfo.environment
            ) else {
                telemetry.breadcrumb("claude-hook.task-sync.nested-suppressed")
                printClaudeHookAck()
                return
            }

            let tasksRootURL = ClaudeTaskRootResolver(
                environment: ProcessInfo.processInfo.environment,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            ).resolve()
            let loader = ClaudeTaskSnapshotLoader(tasksRootURL: tasksRootURL)
            try withClaudeTaskSnapshotLock(loader: loader) {
                let todos = try loader.load(sessionID: sessionID)
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
                    claudeTaskChecklistDictionary($0, sessionID: sessionID)
                }
                do {
                    _ = try client.sendV2(
                        method: "workspace.todo.reconcile",
                        params: [
                            "workspace_id": resolvedTarget.workspaceId,
                            "owner_id": claudeTaskChecklistOwnerID(sessionID: sessionID),
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
        sessionID: String
    ) -> [String: Any] {
        [
            "id": claudeTaskChecklistID(sessionID: sessionID, taskID: todo.id).uuidString,
            "text": todo.displayContent,
            "state": claudeTaskState(todo.state, workspaceWireFormat: true),
            "origin": "agent",
        ]
    }

    private func claudeTaskChecklistOwnerID(sessionID: String) -> String {
        "claude:\(sessionID)"
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

    private func claudeTaskChecklistID(sessionID: String, taskID: String) -> UUID {
        let name = "cmux.claude-task\0\(sessionID)\0\(taskID)"
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
