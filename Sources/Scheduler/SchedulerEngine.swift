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
    /// Task 7 will wire this to actually launch a Ghostty terminal surface.
    var onTaskDue: ((ScheduledTask, TaskRun) -> Void)?

    private var timer: DispatchSourceTimer?
    private let persistenceFileURL: URL?

    /// Interval between schedule evaluations (30 seconds).
    static let evaluationInterval: TimeInterval = 30

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
}
