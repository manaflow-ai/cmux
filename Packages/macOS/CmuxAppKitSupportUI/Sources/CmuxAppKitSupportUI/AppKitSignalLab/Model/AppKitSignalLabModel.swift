import Foundation

@MainActor
final class AppKitSignalLabModel {
    let graph: SignalGraph
    let tasks: Signal<[AppKitSignalLabTask]>
    let query: Signal<String>
    let draftTaskTitle: Signal<String>
    let filter: Signal<AppKitSignalLabFilter>
    let selectedTaskID: Signal<UUID?>
    let capacity: Signal<Double>
    let automationEnabled: Signal<Bool>
    let activity: Signal<[String]>
    let filteredTasks: SignalMemo<[AppKitSignalLabTask]>
    let selectedTask: SignalMemo<AppKitSignalLabTask?>
    let metrics: SignalMemo<AppKitSignalLabMetrics>
    let canAddTask: SignalMemo<Bool>

    init() {
        let graph = SignalGraph()
        let initialTasks = Self.makeFixtureTasks()
        let tasks = graph.createSignal(initialTasks)
        let query = graph.createSignal("")
        let draftTaskTitle = graph.createSignal("")
        let filter = graph.createSignal(AppKitSignalLabFilter.all)
        let selectedTaskID = graph.createSignal(initialTasks.first?.id)
        let capacity = graph.createSignal(0.74)
        let automationEnabled = graph.createSignal(true)

        self.graph = graph
        self.tasks = tasks
        self.query = query
        self.draftTaskTitle = draftTaskTitle
        self.filter = filter
        self.selectedTaskID = selectedTaskID
        self.capacity = capacity
        self.automationEnabled = automationEnabled
        self.activity = graph.createSignal([
            String(localized: "debug.signalLab.activity.seeded", defaultValue: "Signal graph seeded with eight todos."),
            String(localized: "debug.signalLab.activity.ready", defaultValue: "Fine-grained todo bindings are live."),
        ])

        self.filteredTasks = graph.createMemo { [tasks, query, filter] in
            let normalizedQuery = query.get().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return tasks.get().filter { task in
                filter.get().includes(task.status)
                    && (normalizedQuery.isEmpty
                        || task.title.lowercased().contains(normalizedQuery)
                        || task.owner.lowercased().contains(normalizedQuery))
            }
        }
        self.selectedTask = graph.createMemo { [tasks, selectedTaskID] in
            guard let identifier = selectedTaskID.get() else { return nil }
            return tasks.get().first { $0.id == identifier }
        }
        self.metrics = graph.createMemo { [tasks, capacity, automationEnabled] in
            let values = tasks.get()
            let activeCount = values.filter { $0.status == .running || $0.status == .review }.count
            let blockedCount = values.filter { $0.status == .blocked }.count
            let completedCount = values.filter { $0.status == .complete }.count
            let averageProgress = values.isEmpty
                ? 0
                : values.reduce(0) { $0 + $1.progress } / Double(values.count)
            let utilization = capacity.get()
            let automation = automationEnabled.get()
            let throughput = completedCount * 12 + activeCount * (automation ? 4 : 2)
            let health = max(0, min(1, 0.96 - Double(blockedCount) * 0.12 - abs(utilization - 0.75) * 0.35))
            return AppKitSignalLabMetrics(
                activeCount: activeCount,
                blockedCount: blockedCount,
                completedCount: completedCount,
                averageProgress: averageProgress,
                throughput: throughput,
                health: health,
                capacity: utilization,
                automationEnabled: automation
            )
        }
        self.canAddTask = graph.createMemo { [draftTaskTitle] in
            !draftTaskTitle.get().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func addDraftTask() {
        let title = draftTaskTitle.get().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = AppKitSignalLabTask(
            id: UUID(),
            title: title,
            owner: String(localized: "debug.signalLab.owner.personal", defaultValue: "Personal"),
            status: .queued,
            progress: 0,
            priority: 2
        )
        graph.batch {
            tasks.update { [task] + $0 }
            selectedTaskID.set(task.id)
            draftTaskTitle.set("")
            appendActivity(String(localized: "debug.signalLab.activity.added", defaultValue: "Added a new todo in one batch."))
        }
    }

    func toggleCompletion(at filteredIndex: Int) {
        let visibleTasks = filteredTasks.get()
        guard visibleTasks.indices.contains(filteredIndex) else { return }
        let identifier = visibleTasks[filteredIndex].id
        graph.batch {
            tasks.update { tasks in
                tasks.map { task in
                    guard task.id == identifier else { return task }
                    var updatedTask = task
                    if task.status == .complete {
                        updatedTask.status = .queued
                        updatedTask.progress = 0
                    } else {
                        updatedTask.status = .complete
                        updatedTask.progress = 1
                    }
                    return updatedTask
                }
            }
            selectedTaskID.set(identifier)
            appendActivity(String(localized: "debug.signalLab.activity.completionToggled", defaultValue: "Toggled a todo's completion state."))
        }
    }

    func clearCompletedTasks() {
        let completedIDs = Set(tasks.get().filter { $0.status == .complete }.map(\.id))
        guard !completedIDs.isEmpty else { return }
        graph.batch {
            tasks.update { $0.filter { !completedIDs.contains($0.id) } }
            if let selectedID = selectedTaskID.get(), completedIDs.contains(selectedID) {
                selectedTaskID.set(tasks.get().first?.id)
            }
            appendActivity(String(localized: "debug.signalLab.activity.cleared", defaultValue: "Cleared completed todos."))
        }
    }

    func selectTask(at filteredIndex: Int) {
        let visibleTasks = filteredTasks.get()
        guard visibleTasks.indices.contains(filteredIndex) else {
            selectedTaskID.set(nil)
            return
        }
        selectedTaskID.set(visibleTasks[filteredIndex].id)
    }

    func advanceSelectedTask() {
        guard let selectedID = selectedTaskID.get() else { return }
        graph.batch {
            tasks.update { tasks in
                tasks.map { task in
                    guard task.id == selectedID else { return task }
                    var updatedTask = task
                    updatedTask.progress = min(1, task.progress + 0.18)
                    updatedTask.status = Self.nextStatus(after: task.status, progress: updatedTask.progress)
                    return updatedTask
                }
            }
            appendActivity(String(localized: "debug.signalLab.activity.advanced", defaultValue: "Selected todo advanced in one batch."))
        }
    }

    func toggleBlockedForSelectedTask() {
        guard let selectedID = selectedTaskID.get() else { return }
        graph.batch {
            tasks.update { tasks in
                tasks.map { task in
                    guard task.id == selectedID else { return task }
                    var updatedTask = task
                    updatedTask.status = task.status == .blocked ? .running : .blocked
                    return updatedTask
                }
            }
            appendActivity(String(localized: "debug.signalLab.activity.blockToggled", defaultValue: "Selected todo's blocked state changed."))
        }
    }

    func setSelectedPriority(_ priority: Int) {
        guard let selectedID = selectedTaskID.get() else { return }
        tasks.update { tasks in
            tasks.map { task in
                guard task.id == selectedID else { return task }
                var updatedTask = task
                updatedTask.priority = priority
                return updatedTask
            }
        }
    }

    func runSimulationStep() {
        graph.batch {
            tasks.update { tasks in
                tasks.map { task in
                    guard task.status == .running else { return task }
                    var updatedTask = task
                    updatedTask.progress = min(1, task.progress + 0.07)
                    if updatedTask.progress >= 1 {
                        updatedTask.status = .complete
                    }
                    return updatedTask
                }
            }
            capacity.update { value in value > 0.88 ? 0.62 : value + 0.06 }
            appendActivity(String(localized: "debug.signalLab.activity.simulated", defaultValue: "Demo step updated todo progress atomically."))
        }
    }

    private func appendActivity(_ message: String) {
        activity.update { entries in
            Array(([message] + entries).prefix(5))
        }
    }

    private static func nextStatus(after status: AppKitSignalLabStatus, progress: Double) -> AppKitSignalLabStatus {
        if progress >= 1 { return .complete }
        switch status {
        case .queued: return .running
        case .running: return .review
        case .review: return .complete
        case .blocked: return .running
        case .complete: return .complete
        }
    }

    private static func makeFixtureTasks() -> [AppKitSignalLabTask] {
        [
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.renderPipeline", defaultValue: "Rebuild render pipeline"),
                owner: String(localized: "debug.signalLab.owner.runtime", defaultValue: "Runtime"),
                status: .running,
                progress: 0.68,
                priority: 1
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.indexWorkspace", defaultValue: "Index workspace history"),
                owner: String(localized: "debug.signalLab.owner.search", defaultValue: "Search"),
                status: .review,
                progress: 0.86,
                priority: 2
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.notarizeBuild", defaultValue: "Notarize release build"),
                owner: String(localized: "debug.signalLab.owner.release", defaultValue: "Release"),
                status: .blocked,
                progress: 0.41,
                priority: 1
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.syncSessions", defaultValue: "Sync remote sessions"),
                owner: String(localized: "debug.signalLab.owner.cloud", defaultValue: "Cloud"),
                status: .running,
                progress: 0.54,
                priority: 2
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.auditShortcuts", defaultValue: "Audit command shortcuts"),
                owner: String(localized: "debug.signalLab.owner.desktop", defaultValue: "Desktop"),
                status: .queued,
                progress: 0.12,
                priority: 3
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.profileStartup", defaultValue: "Profile startup path"),
                owner: String(localized: "debug.signalLab.owner.performance", defaultValue: "Performance"),
                status: .complete,
                progress: 1,
                priority: 2
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.validateThemes", defaultValue: "Validate terminal themes"),
                owner: String(localized: "debug.signalLab.owner.design", defaultValue: "Design"),
                status: .complete,
                progress: 1,
                priority: 3
            ),
            AppKitSignalLabTask(
                id: UUID(),
                title: String(localized: "debug.signalLab.task.compressSnapshots", defaultValue: "Compress session snapshots"),
                owner: String(localized: "debug.signalLab.owner.storage", defaultValue: "Storage"),
                status: .queued,
                progress: 0.05,
                priority: 2
            ),
        ]
    }
}
