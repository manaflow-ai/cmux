import Foundation
import Combine

// MARK: - SchedulerEngine

/// Core scheduling engine that evaluates cron schedules on a 30-second timer,
/// creates TaskRun records for due tasks, and manages run lifecycle.
///
/// Injected as `.environmentObject(SchedulerEngine.shared)` at both
/// `cmuxApp.swift` and `AppDelegate.swift` (required for multi-window support).
@MainActor
final class SchedulerEngine: ObservableObject {
    static let shared = SchedulerEngine()

    @Published var tasks: [ScheduledTask] = []
    @Published var runs: [TaskRun] = []

    /// Maximum number of concurrently running tasks. Prevents runaway resource usage.
    var maxConcurrentTasks: Int = 10

    /// Tracks the last time schedules were evaluated, preventing duplicate fires
    /// when the timer ticks faster than the cron resolution (1 minute).
    var lastEvaluatedAt: Date

    /// Called when a task is due and a TaskRun has been created.
    /// Wired to `executeTask(_:run:)` via `onTaskDue` in production;
    /// left nil in tests for pure evaluation logic testing.
    var onTaskDue: ((ScheduledTask, TaskRun) -> Void)?

    /// Maps panelId -> runId for tracking which terminal surface belongs to which run.
    var panelToRunId: [UUID: UUID] = [:]

    /// Maps runId -> worktree info for cleanup after task completion.
    var runWorktreeInfo: [UUID: (repoPath: String, worktreePath: String)] = [:]

    /// Injectable git command runner (swapped in tests).
    var gitRunner: GitCommandRunner = ProcessGitCommandRunner()

    /// The workspace ID used for scheduler task terminals (lazily created).
    var schedulerWorkspaceId: UUID?

    /// Maps runId -> workspaceId for per-run workspace tracking (used by Focus).
    var runToWorkspaceId: [UUID: UUID] = [:]

    private var timer: DispatchSourceTimer?
    private let persistenceFileURL: URL?

    /// Whether the evaluation timer is currently running.
    var isTimerRunning: Bool { timer != nil }

    /// Interval between schedule evaluations (30 seconds).
    static let evaluationInterval: TimeInterval = 30

    /// Maximum chain depth for onSuccess/onFailure task chaining.
    /// Prevents infinite loops (e.g., A -> B -> A -> B ...).
    static let maxChainDepth = 3

    /// Maximum number of completed runs to retain in memory.
    /// Oldest completed runs are pruned when this limit is exceeded.
    static let maxCompletedRuns = 500

    /// Shared date formatter for ISO8601 serialization.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Directory for session memory context files.
    static let contextDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("cmux/scheduler-context", isDirectory: true)
    }()

    // MARK: - Init

    init(persistenceFileURL: URL? = nil, now: Date = Date()) {
        self.persistenceFileURL = persistenceFileURL
        self.lastEvaluatedAt = now
        loadTasks()
        cleanupStaleRuns()
    }

    // MARK: - Timer

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + Self.evaluationInterval,
            repeating: Self.evaluationInterval,
            leeway: .seconds(2)
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.evaluateSchedules()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Evaluation

    /// Evaluate all enabled tasks and fire any that are due.
    /// Returns the list of newly created TaskRun records (useful for testing).
    @discardableResult
    func evaluateSchedules(now: Date = Date()) -> [TaskRun] {
        var newRuns: [TaskRun] = []
        let runningCount = runs.filter { $0.status == .running }.count

        for task in tasks {
            guard task.isEnabled else { continue }

            // Check if this task is due: its next fire date (after last evaluation) is <= now
            guard let nextFire = task.nextFireDate(after: lastEvaluatedAt),
                  nextFire <= now else { continue }

            // Check overlap: skip if already running and overlap not allowed
            if !task.allowOverlap {
                let alreadyRunning = runs.contains { $0.taskId == task.id && $0.status == .running }
                if alreadyRunning { continue }
            }

            // Check concurrent task limit
            if runningCount + newRuns.count >= maxConcurrentTasks { break }

            // Create a new run
            let run = TaskRun(taskId: task.id, startedAt: now)
            runs.append(run)
            newRuns.append(run)

            onTaskDue?(task, run)
        }

        lastEvaluatedAt = now
        return newRuns
    }

    // MARK: - Run Pruning

    /// Remove oldest completed runs when the count exceeds `maxCompletedRuns`.
    private func pruneCompletedRuns() {
        let completedRuns = runs.filter { $0.status != .running }
        guard completedRuns.count > Self.maxCompletedRuns else { return }
        let sorted = completedRuns.sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        let excess = completedRuns.count - Self.maxCompletedRuns
        let idsToRemove = Set(sorted.prefix(excess).map(\.id))
        runs.removeAll { idsToRemove.contains($0.id) }
    }

    // MARK: - Startup Cleanup

    /// Mark any stale `.running` records as `.cancelled` on startup.
    /// If the app crashed or was force-quit, these runs never completed.
    func cleanupStaleRuns() {
        for i in runs.indices {
            if runs[i].status == .running {
                runs[i].status = .cancelled
                runs[i].completedAt = Date()
            }
        }
        pruneCompletedRuns()
    }

    // MARK: - Persistence

    func loadTasks() {
        tasks = SchedulerPersistenceStore.load(fileURL: persistenceFileURL)
    }

    func saveTasks() {
        SchedulerPersistenceStore.save(tasks, fileURL: persistenceFileURL)
    }

    // MARK: - Task Management

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        saveTasks()
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        saveTasks()
    }

    func updateTask(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
            saveTasks()
        }
    }

    // MARK: - Run Queries

    func activeRuns(for taskId: UUID) -> [TaskRun] {
        runs.filter { $0.taskId == taskId && $0.status == .running }
    }

    var runningTaskCount: Int {
        runs.filter { $0.status == .running }.count
    }

    // MARK: - Manual Run

    /// Trigger a manual "Run Now" with overlap and concurrent task limit checks.
    /// Returns the new TaskRun on success, or nil if blocked by constraints.
    func manuallyRunTask(_ task: ScheduledTask) -> TaskRun? {
        if !task.allowOverlap {
            let alreadyRunning = runs.contains { $0.taskId == task.id && $0.status == .running }
            if alreadyRunning { return nil }
        }
        if runningTaskCount >= maxConcurrentTasks { return nil }

        let run = TaskRun(taskId: task.id, startedAt: Date())
        runs.append(run)
        onTaskDue?(task, run)
        return run
    }

    // MARK: - Task Execution

    /// Execute a scheduled task by creating a dedicated workspace with a terminal
    /// that runs the command via Ghostty's native `config.command`.
    ///
    /// Each task run gets its own workspace so that Focus is a simple workspace
    /// switch — no bonsplit tab navigation required.
    func executeTask(_ task: ScheduledTask, run: TaskRun, tabManager: TabManager) {
        // Resolve working directory (may create a git worktree if isolation is enabled)
        let worktreeResult = WorktreeIsolation.resolveWorkingDirectory(
            task: task,
            runId: run.id,
            gitRunner: gitRunner
        )
        let effectiveWorkDir = worktreeResult.effectiveDirectory

        // Track worktree for cleanup after task completes
        if let wtPath = worktreeResult.worktreePath,
           let repoPath = task.workingDirectory {
            runWorktreeInfo[run.id] = (repoPath: repoPath, worktreePath: wtPath)
        }

        // Build environment with session memory context
        var env: [String: String] = task.environment ?? [:]
        env["CMUX_SCHEDULED_TASK_ID"] = task.id.uuidString
        env["CMUX_SCHEDULED_TASK_NAME"] = task.name
        env["CMUX_TASK_RUN_ID"] = run.id.uuidString
        if let wtPath = worktreeResult.worktreePath {
            env["CMUX_WORKTREE_PATH"] = wtPath
        }

        // Create session memory context file
        let contextFileURL = Self.contextDirectory
            .appendingPathComponent("\(run.id.uuidString).json")
        createContextFile(for: task, run: run, at: contextFileURL)
        env["CMUX_TASK_CONTEXT_FILE"] = contextFileURL.path

        // Create a dedicated workspace for this run (non-intrusive: don't select it).
        let workspace = tabManager.addWorkspace(
            workingDirectory: effectiveWorkDir,
            select: false
        )
        workspace.customTitle = "[\(task.name)]"

        // Track workspace for this run (used by Focus and snapshot)
        runToWorkspaceId[run.id] = workspace.id
        schedulerWorkspaceId = workspace.id

        // Create a terminal panel that uses initial_input to inject the command
        // into the shell after it starts. Environment variables are passed via
        // additionalEnvironment (set on the process before the shell starts),
        // so no export commands are needed in the input.
        //
        // The initial_input sequence:
        //   1. clear — start with a clean terminal
        //   2. banner — show task name and timestamp for context
        //   3. command — the actual task command (exit code captured)
        //   4. completion message — indicate review mode with exit code
        let safeName = task.name.replacingOccurrences(of: "'", with: "")
        let banner = "echo '--- \(safeName) ---'; echo ''"
        let doneMsg = "echo ''; echo \"--- Task finished (exit $CMUX_EXIT) --- Output above is read-only. Close tab when done.\""
        let fullCommand = "clear; \(banner); \(task.command); CMUX_EXIT=$?; \(doneMsg); exit $CMUX_EXIT\n"

        // wait_after_command keeps the terminal visible after the shell exits
        // (triggered by `exit $CMUX_EXIT` at the end of initial_input) so the
        // user can review output. This also triggers COMMAND_FINISHED for status tracking.
        var config = ghostty_surface_config_new()
        config.wait_after_command = true

        let panel = TerminalPanel(
            workspaceId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: config,
            workingDirectory: effectiveWorkDir,
            initialInput: fullCommand,
            additionalEnvironment: env
        )

        // Add to workspace, then ensure bonsplit's focused pane and selected tab
        // point to the task terminal. Without focusPane, focusedPanelId returns nil
        // when the workspace is later selected, causing a transparent terminal.
        workspace.addTerminalPanel(panel, title: "[\(task.name)]")
        if let tabId = workspace.surfaceIdFromPanelId(panel.id) {
            // Find the pane containing the task terminal's tab
            let paneToFocus = workspace.bonsplitController.allPaneIds.first(where: { paneId in
                workspace.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
            })
            if let paneToFocus {
                workspace.bonsplitController.focusPane(paneToFocus)
            }
            workspace.bonsplitController.selectTab(tabId)
        }

        // Track panel -> run mapping
        panelToRunId[panel.id] = run.id

        // Update run with panel ID
        if let runIndex = runs.firstIndex(where: { $0.id == run.id }) {
            runs[runIndex].panelId = panel.id
        }
    }

    /// Handle COMMAND_FINISHED callback from Ghostty.
    /// Called from the action handler in GhosttyTerminalView.swift.
    func handleTaskCompletion(panelId: UUID, exitCode: Int32, workspaceId: UUID?) {
        guard let runId = panelToRunId[panelId],
              let runIndex = runs.firstIndex(where: { $0.id == runId }) else { return }

        // If the run was already cancelled (e.g., by cancelTask racing with COMMAND_FINISHED),
        // do not overwrite its status or re-trigger cleanup/chaining.
        guard runs[runIndex].status == .running else { return }

        let currentChainDepth = runs[runIndex].chainDepth

        runs[runIndex].status = exitCode == 0 ? .succeeded : .failed
        runs[runIndex].exitCode = exitCode
        runs[runIndex].completedAt = Date()

        panelToRunId.removeValue(forKey: panelId)
        runToWorkspaceId.removeValue(forKey: runId)

        // Look up the task for notification and chaining
        let taskId = runs[runIndex].taskId
        let task = tasks.first(where: { $0.id == taskId })
        let taskName = task?.name ?? "Unknown Task"

        // Fire notification via TerminalNotificationStore
        let statusText = exitCode == 0 ? "completed successfully" : "failed (exit \(exitCode))"
        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId ?? schedulerWorkspaceId ?? UUID(),
            surfaceId: panelId,
            title: taskName,
            subtitle: "Scheduled Task",
            body: "Task \(statusText)"
        )

        // Clean up worktree if one was created for this run
        if let wtInfo = runWorktreeInfo.removeValue(forKey: runId) {
            WorktreeIsolation.cleanupWorktree(
                repoPath: wtInfo.repoPath,
                worktreePath: wtInfo.worktreePath,
                gitRunner: gitRunner
            )
        }

        // Clean up context file
        let contextFile = Self.contextDirectory.appendingPathComponent("\(runId).json")
        try? FileManager.default.removeItem(at: contextFile)

        // Task chaining: trigger onSuccess/onFailure follow-up task.
        // Apply the same guards (isEnabled, overlap, concurrency) as evaluateSchedules.
        if currentChainDepth < Self.maxChainDepth, let task = task {
            let chainTargetId: String? = exitCode == 0 ? task.onSuccess : task.onFailure
            if let targetIdString = chainTargetId,
               let targetId = UUID(uuidString: targetIdString),
               let targetTask = tasks.first(where: { $0.id == targetId }),
               targetTask.isEnabled {
                var blocked = false
                if !targetTask.allowOverlap {
                    blocked = runs.contains { $0.taskId == targetTask.id && $0.status == .running }
                }
                if !blocked && runningTaskCount >= maxConcurrentTasks {
                    blocked = true
                }
                if !blocked {
                    let chainRun = TaskRun(
                        taskId: targetTask.id,
                        startedAt: Date(),
                        chainDepth: currentChainDepth + 1
                    )
                    runs.append(chainRun)
                    onTaskDue?(targetTask, chainRun)
                }
            }
        }

        pruneCompletedRuns()
    }

    /// Cancel a running task by requesting its terminal surface to close.
    func cancelTask(runId: UUID) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runId }),
              runs[runIndex].status == .running else { return }

        // Find the panel and request close on its surface
        if let panelId = runs[runIndex].panelId,
           let app = AppDelegate.shared,
           let tabManager = app.tabManager,
           let wsId = runToWorkspaceId[runId] ?? schedulerWorkspaceId,
           let workspace = tabManager.tabs.first(where: { $0.id == wsId }),
           let panel = workspace.panels[panelId] as? TerminalPanel,
           let surface = panel.surface.surface {
            ghostty_surface_request_close(surface)
        }

        // Mark as cancelled regardless of whether we found the surface
        runs[runIndex].status = .cancelled
        runs[runIndex].completedAt = Date()

        if let panelId = runs[runIndex].panelId {
            panelToRunId.removeValue(forKey: panelId)
        }

        // Clean up worktree if one was created for this run
        if let wtInfo = runWorktreeInfo.removeValue(forKey: runId) {
            WorktreeIsolation.cleanupWorktree(
                repoPath: wtInfo.repoPath,
                worktreePath: wtInfo.worktreePath,
                gitRunner: gitRunner
            )
        }

        // Clean up context file
        let contextFile = Self.contextDirectory.appendingPathComponent("\(runId).json")
        try? FileManager.default.removeItem(at: contextFile)

        pruneCompletedRuns()
    }

    /// Focus a running task's terminal by switching to its dedicated workspace.
    func focusRunningTask(runId: UUID) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runId }),
              runs[runIndex].status == .running,
              let workspaceId = runToWorkspaceId[runId],
              let app = AppDelegate.shared,
              let tabManager = app.tabManager else {
            return
        }

        // Each run has its own workspace — just switch to it.
        tabManager.selectedTabId = workspaceId
    }

    // MARK: - Session Memory

    /// Create a context file with task metadata for the running command to read.
    func createContextFile(for task: ScheduledTask, run: TaskRun, at url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let context: [String: Any] = [
            "task_id": task.id.uuidString,
            "task_name": task.name,
            "run_id": run.id.uuidString,
            "command": task.command,
            "working_directory": task.workingDirectory ?? "",
            "cron_expression": task.cronExpression,
            "started_at": Self.isoFormatter.string(from: run.startedAt),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    // MARK: - App Quit Cleanup

    /// Persist state and cancel running tasks on app termination.
    func handleAppWillTerminate() {
        // Cancel all running tasks and clean up worktrees
        for i in runs.indices {
            if runs[i].status == .running {
                runs[i].status = .cancelled
                runs[i].completedAt = Date()
                if let panelId = runs[i].panelId {
                    panelToRunId.removeValue(forKey: panelId)
                }
                if let wtInfo = runWorktreeInfo.removeValue(forKey: runs[i].id) {
                    WorktreeIsolation.cleanupWorktree(
                        repoPath: wtInfo.repoPath,
                        worktreePath: wtInfo.worktreePath,
                        gitRunner: gitRunner
                    )
                }
            }
        }

        // Persist final task list
        saveTasks()

        // Stop the evaluation timer
        stop()
    }
}
