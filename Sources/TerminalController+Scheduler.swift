import Foundation

// MARK: - Scheduler v2 Socket API

extension TerminalController {

    /// Dispatch a scheduler.* v2 method. Returns the V2CallResult for the given method.
    func v2SchedulerDispatch(method: String, params: [String: Any]) -> V2CallResult {
        switch method {
        case "scheduler.list":
            return v2SchedulerList(params: params)
        case "scheduler.create":
            return v2SchedulerCreate(params: params)
        case "scheduler.delete":
            return v2SchedulerDelete(params: params)
        case "scheduler.update":
            return v2SchedulerUpdate(params: params)
        case "scheduler.enable":
            return v2SchedulerEnable(params: params)
        case "scheduler.disable":
            return v2SchedulerDisable(params: params)
        case "scheduler.run":
            return v2SchedulerRun(params: params)
        case "scheduler.cancel":
            return v2SchedulerCancel(params: params)
        case "scheduler.logs":
            return v2SchedulerLogs(params: params)
        case "scheduler.snapshot":
            return v2SchedulerSnapshot(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown scheduler method", data: nil)
        }
    }

    // MARK: - scheduler.list

    private func v2SchedulerList(params: [String: Any]) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to list tasks", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            let taskDicts: [[String: Any]] = engine.tasks.map { task in
                var dict = schedulerTaskDict(task)
                // Include last run info
                let lastRun = engine.runs
                    .filter { $0.taskId == task.id }
                    .sorted(by: { $0.startedAt > $1.startedAt })
                    .first
                if let lastRun {
                    dict["last_run"] = schedulerRunDict(lastRun)
                }
                // Include active run count
                let activeCount = engine.runs.filter { $0.taskId == task.id && $0.status == .running }.count
                dict["active_runs"] = activeCount
                return dict
            }
            result = .ok(["tasks": taskDicts, "count": taskDicts.count])
        }
        return result
    }

    // MARK: - scheduler.create

    // Input length limits to prevent resource exhaustion
    private static let maxNameLength = 256
    private static let maxCommandLength = 65536
    private static let maxCronLength = 128
    private static let maxPathLength = 4096
    private static let maxEnvEntries = 100
    private static let maxEnvValueLength = 4096
    private static let maxTasks = 500

    // Environment variable names that cannot be set via scheduler API
    private static let blockedEnvKeys: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
        "BASH_ENV", "ENV", "PROMPT_COMMAND",
    ]

    private func v2SchedulerCreate(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty 'name'", data: nil)
        }
        guard let cronExpression = params["cron"] as? String,
              !cronExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty 'cron'", data: nil)
        }
        guard let command = params["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty 'command'", data: nil)
        }

        // Enforce length limits
        guard name.count <= Self.maxNameLength else {
            return .err(code: "invalid_params", message: "Name exceeds maximum length (\(Self.maxNameLength))", data: nil)
        }
        guard command.count <= Self.maxCommandLength else {
            return .err(code: "invalid_params", message: "Command exceeds maximum length (\(Self.maxCommandLength))", data: nil)
        }
        guard cronExpression.count <= Self.maxCronLength else {
            return .err(code: "invalid_params", message: "Cron expression exceeds maximum length (\(Self.maxCronLength))", data: nil)
        }
        if let workDir = params["working_directory"] as? String, workDir.count > Self.maxPathLength {
            return .err(code: "invalid_params", message: "Working directory exceeds maximum length (\(Self.maxPathLength))", data: nil)
        }

        // Validate environment: entry count, value lengths, blocked keys
        if let env = params["environment"] as? [String: String] {
            guard env.count <= Self.maxEnvEntries else {
                return .err(code: "invalid_params", message: "Environment exceeds maximum entries (\(Self.maxEnvEntries))", data: nil)
            }
            for (key, value) in env {
                if Self.blockedEnvKeys.contains(key) || key.hasPrefix("DYLD_") || key.hasPrefix("LD_") {
                    return .err(code: "invalid_params", message: "Environment variable '\(key)' is not allowed", data: nil)
                }
                if value.count > Self.maxEnvValueLength {
                    return .err(code: "invalid_params", message: "Environment value for '\(key)' exceeds maximum length", data: nil)
                }
            }
        }

        // Validate cron expression
        let trimmedCron = cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CronExpression(trimmedCron) != nil else {
            return .err(code: "invalid_cron", message: "Invalid cron expression", data: nil)
        }

        let task = ScheduledTask(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cronExpression: trimmedCron,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            workingDirectory: (params["working_directory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: params["environment"] as? [String: String],
            isEnabled: (params["is_enabled"] as? Bool) ?? true,
            allowOverlap: (params["allow_overlap"] as? Bool) ?? false,
            useWorktree: params["use_worktree"] as? Bool,
            onSuccess: params["on_success"] as? String,
            onFailure: params["on_failure"] as? String
        )

        // Validate onSuccess/onFailure are valid UUIDs if provided
        if let onSuccess = task.onSuccess, UUID(uuidString: onSuccess) == nil {
            return .err(code: "invalid_params", message: "on_success must be a valid UUID", data: nil)
        }
        if let onFailure = task.onFailure, UUID(uuidString: onFailure) == nil {
            return .err(code: "invalid_params", message: "on_failure must be a valid UUID", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create task", data: nil)
        v2MainSync {
            guard SchedulerEngine.shared.tasks.count < Self.maxTasks else {
                result = .err(code: "limit_reached", message: "Maximum task definitions reached (\(Self.maxTasks))", data: nil)
                return
            }
            SchedulerEngine.shared.addTask(task)
            result = .ok(["task_id": task.id.uuidString, "task": schedulerTaskDict(task)])
        }
        return result
    }

    // MARK: - scheduler.delete

    private func v2SchedulerDelete(params: [String: Any]) -> V2CallResult {
        guard let taskIdStr = params["task_id"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'task_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to delete task", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard engine.tasks.contains(where: { $0.id == taskId }) else {
                result = .err(code: "not_found", message: "Task not found", data: ["task_id": taskIdStr])
                return
            }
            // Cancel any active runs first
            let activeRuns = engine.runs.filter { $0.taskId == taskId && $0.status == .running }
            for run in activeRuns {
                engine.cancelTask(runId: run.id)
            }
            engine.removeTask(id: taskId)
            result = .ok(["deleted": true, "task_id": taskIdStr])
        }
        return result
    }

    // MARK: - scheduler.update

    private func v2SchedulerUpdate(params: [String: Any]) -> V2CallResult {
        guard let taskIdStr = params["task_id"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'task_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to update task", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard var task = engine.tasks.first(where: { $0.id == taskId }) else {
                result = .err(code: "not_found", message: "Task not found", data: ["task_id": taskIdStr])
                return
            }

            // Apply updates for provided fields
            if let name = params["name"] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    result = .err(code: "invalid_params", message: "Name cannot be empty", data: nil)
                    return
                }
                task.name = trimmed
            }
            if let cron = params["cron"] as? String {
                let trimmedCron = cron.trimmingCharacters(in: .whitespacesAndNewlines)
                guard CronExpression(trimmedCron) != nil else {
                    result = .err(code: "invalid_cron", message: "Invalid cron expression", data: nil)
                    return
                }
                task.cronExpression = trimmedCron
            }
            if let command = params["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    result = .err(code: "invalid_params", message: "Command cannot be empty", data: nil)
                    return
                }
                task.command = trimmed
            }
            if let workDir = params["working_directory"] as? String {
                let trimmed = workDir.trimmingCharacters(in: .whitespacesAndNewlines)
                task.workingDirectory = trimmed.isEmpty ? nil : trimmed
            }
            if let env = params["environment"] as? [String: String] {
                task.environment = env
            }
            if let enabled = params["is_enabled"] as? Bool {
                task.isEnabled = enabled
            }
            if let overlap = params["allow_overlap"] as? Bool {
                task.allowOverlap = overlap
            }
            if params.keys.contains("use_worktree") {
                task.useWorktree = params["use_worktree"] as? Bool
            }
            if params.keys.contains("on_success") {
                let val = params["on_success"] as? String
                if let val, UUID(uuidString: val) == nil {
                    result = .err(code: "invalid_params", message: "on_success must be a valid UUID", data: nil)
                    return
                }
                task.onSuccess = val
            }
            if params.keys.contains("on_failure") {
                let val = params["on_failure"] as? String
                if let val, UUID(uuidString: val) == nil {
                    result = .err(code: "invalid_params", message: "on_failure must be a valid UUID", data: nil)
                    return
                }
                task.onFailure = val
            }

            engine.updateTask(task)
            result = .ok(["task_id": taskIdStr, "task": schedulerTaskDict(task)])
        }
        return result
    }

    // MARK: - scheduler.enable

    private func v2SchedulerEnable(params: [String: Any]) -> V2CallResult {
        guard let taskIdStr = params["task_id"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'task_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to enable task", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard var task = engine.tasks.first(where: { $0.id == taskId }) else {
                result = .err(code: "not_found", message: "Task not found", data: ["task_id": taskIdStr])
                return
            }
            task.isEnabled = true
            engine.updateTask(task)
            result = .ok(["task_id": taskIdStr, "is_enabled": true])
        }
        return result
    }

    // MARK: - scheduler.disable

    private func v2SchedulerDisable(params: [String: Any]) -> V2CallResult {
        guard let taskIdStr = params["task_id"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'task_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to disable task", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard var task = engine.tasks.first(where: { $0.id == taskId }) else {
                result = .err(code: "not_found", message: "Task not found", data: ["task_id": taskIdStr])
                return
            }
            task.isEnabled = false
            engine.updateTask(task)
            result = .ok(["task_id": taskIdStr, "is_enabled": false])
        }
        return result
    }

    // MARK: - scheduler.run

    private func v2SchedulerRun(params: [String: Any]) -> V2CallResult {
        guard let taskIdStr = params["task_id"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'task_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to run task", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard let task = engine.tasks.first(where: { $0.id == taskId }) else {
                result = .err(code: "not_found", message: "Task not found", data: ["task_id": taskIdStr])
                return
            }

            // Delegate to manuallyRunTask which handles overlap and concurrency checks
            guard let run = engine.manuallyRunTask(task) else {
                // Distinguish between overlap and limit failures
                if !task.allowOverlap && engine.runs.contains(where: { $0.taskId == taskId && $0.status == .running }) {
                    result = .err(code: "already_running", message: "Task is already running and allow_overlap is false", data: ["task_id": taskIdStr])
                } else {
                    result = .err(code: "limit_reached", message: "Max concurrent tasks limit reached (\(engine.maxConcurrentTasks))", data: nil)
                }
                return
            }

            result = .ok([
                "task_id": taskIdStr,
                "run_id": run.id.uuidString,
                "run": schedulerRunDict(run)
            ])
        }
        return result
    }

    // MARK: - scheduler.cancel

    private func v2SchedulerCancel(params: [String: Any]) -> V2CallResult {
        guard let runIdStr = params["run_id"] as? String,
              let runId = UUID(uuidString: runIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'run_id'", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to cancel run", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard let run = engine.runs.first(where: { $0.id == runId }) else {
                result = .err(code: "not_found", message: "Run not found", data: ["run_id": runIdStr])
                return
            }
            guard run.status == .running else {
                result = .err(code: "invalid_state", message: "Run is not in a cancellable state", data: ["run_id": runIdStr])
                return
            }
            engine.cancelTask(runId: runId)
            result = .ok(["run_id": runIdStr, "cancelled": true])
        }
        return result
    }

    // MARK: - scheduler.logs

    private func v2SchedulerLogs(params: [String: Any]) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to get logs", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            var runs = engine.runs

            // Filter by task_id if provided
            if let taskIdStr = params["task_id"] as? String,
               let taskId = UUID(uuidString: taskIdStr) {
                runs = runs.filter { $0.taskId == taskId }
            }

            // Filter by status if provided
            if let statusStr = params["status"] as? String,
               let status = TaskRunStatus(rawValue: statusStr) {
                runs = runs.filter { $0.status == status }
            }

            // Sort by startedAt descending (most recent first)
            runs.sort { $0.startedAt > $1.startedAt }

            // Limit results
            let limit = max(1, min((params["limit"] as? Int) ?? 50, 500))
            if runs.count > limit {
                runs = Array(runs.prefix(limit))
            }

            let runDicts = runs.map { schedulerRunDict($0) }
            result = .ok(["runs": runDicts, "count": runDicts.count])
        }
        return result
    }

    // MARK: - scheduler.snapshot

    private func v2SchedulerSnapshot(params: [String: Any]) -> V2CallResult {
        guard let runIdStr = params["run_id"] as? String,
              let runId = UUID(uuidString: runIdStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid 'run_id'", data: nil)
        }

        let includeScrollback = (params["scrollback"] as? Bool) ?? false
        let lineLimit = params["lines"] as? Int

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to read snapshot", data: nil)
        v2MainSync {
            let engine = SchedulerEngine.shared
            guard let run = engine.runs.first(where: { $0.id == runId }) else {
                result = .err(code: "not_found", message: "Run not found", data: ["run_id": runIdStr])
                return
            }
            guard let panelId = run.panelId else {
                result = .err(code: "no_surface", message: "Run has no associated terminal surface", data: ["run_id": runIdStr])
                return
            }

            // Find the terminal panel via the run's dedicated workspace
            let workspaceId = engine.runToWorkspaceId[runId] ?? engine.schedulerWorkspaceId
            guard let app = AppDelegate.shared,
                  let tabManager = app.tabManager,
                  let wsId = workspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == wsId }),
                  let terminalPanel = workspace.terminalPanel(for: panelId) else {
                result = .err(code: "surface_not_found", message: "Terminal surface not available", data: ["panel_id": panelId.uuidString])
                return
            }

            let response = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
            guard response.hasPrefix("OK ") else {
                result = .err(code: "read_error", message: response, data: nil)
                return
            }
            let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
            guard let text = decoded ?? (base64.isEmpty ? "" : nil) else {
                result = .err(code: "decode_error", message: "Failed to decode terminal text", data: nil)
                return
            }

            result = .ok([
                "run_id": runIdStr,
                "task_id": run.taskId.uuidString,
                "text": text,
                "base64": base64
            ])
        }
        return result
    }

    // MARK: - Serialization Helpers

    private static let isoFormatter = ISO8601DateFormatter()

    private func schedulerTaskDict(_ task: ScheduledTask) -> [String: Any] {
        var dict: [String: Any] = [
            "id": task.id.uuidString,
            "name": task.name,
            "cron": task.cronExpression,
            "command": task.command,
            "is_enabled": task.isEnabled,
            "allow_overlap": task.allowOverlap,
            "created_at": Self.isoFormatter.string(from: task.createdAt)
        ]
        if let workDir = task.workingDirectory { dict["working_directory"] = workDir }
        if let env = task.environment { dict["environment"] = env }
        if let useWorktree = task.useWorktree { dict["use_worktree"] = useWorktree }
        if let onSuccess = task.onSuccess { dict["on_success"] = onSuccess }
        if let onFailure = task.onFailure { dict["on_failure"] = onFailure }

        // Include next fire date if cron is valid
        if let nextFire = task.nextFireDate(after: Date()) {
            dict["next_fire"] = Self.isoFormatter.string(from: nextFire)
        }
        return dict
    }

    private func schedulerRunDict(_ run: TaskRun) -> [String: Any] {
        var dict: [String: Any] = [
            "id": run.id.uuidString,
            "task_id": run.taskId.uuidString,
            "status": run.status.rawValue,
            "started_at": Self.isoFormatter.string(from: run.startedAt)
        ]
        if let panelId = run.panelId { dict["panel_id"] = panelId.uuidString }
        if let completedAt = run.completedAt {
            dict["completed_at"] = Self.isoFormatter.string(from: completedAt)
        }
        if let exitCode = run.exitCode { dict["exit_code"] = exitCode }
        return dict
    }
}
