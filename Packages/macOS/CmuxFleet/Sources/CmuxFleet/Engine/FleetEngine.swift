import Foundation

/// Coordinates Fleet runtime state by driving the pure scheduler and supervisor reducers.
@MainActor
public final class FleetEngine {
    struct FleetRuntimeState {
        var config: FleetConfig
        var isRunning: Bool
        var tasks: [FleetTaskID: FleetTask]
        var taskIDByWorkspaceID: [String: FleetTaskID]
        var currentAgentPIDByTaskID: [FleetTaskID: Int32]
        var provisionGenerationByTaskID: [FleetTaskID: Int]
        var scheduledBackoffAttemptByTaskID: [FleetTaskID: Int]
        var scheduledStallAttemptByTaskID: [FleetTaskID: Int]
    }

    /// The dependencies used for all imperative effects.
    let dependencies: FleetEngineDependencies

    var fleets: [FleetID: FleetRuntimeState] = [:]

    /// Callback fired after Fleet runtime state changes.
    public var onStateChange: (@MainActor () -> Void)?

    /// Creates a Fleet engine and restores persisted state, if any exists.
    /// - Parameter dependencies: The dependencies used for all imperative effects.
    public init(dependencies: FleetEngineDependencies) {
        self.dependencies = dependencies
        restore()
    }

    /// Creates a Fleet configuration.
    /// - Parameters:
    ///   - name: The Fleet display name.
    ///   - repoRoot: The repository root this Fleet manages.
    ///   - agentCommandTemplate: The optional agent command template.
    ///   - maxConcurrent: The optional maximum number of concurrent agents.
    /// - Returns: The created configuration, or a validation failure.
    public func createFleet(
        name: String,
        repoRoot: String,
        agentCommandTemplate: String?,
        maxConcurrent: Int?
    ) -> Result<FleetConfig, FleetCreateError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(.invalidConfiguration("Fleet name is required"))
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoRoot, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .failure(.invalidConfiguration("Repository root must be an existing directory"))
        }

        guard !fleets.values.contains(where: { $0.config.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            return .failure(.invalidConfiguration("Fleet name already exists"))
        }

        let id = FleetID(FleetPathSanitizer().directoryName(for: trimmedName))
        let repoURL = URL(fileURLWithPath: repoRoot)
        let workspaceRoot = repoURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent)-fleet", isDirectory: true)
            .path
        let config = FleetConfig(
            id: id,
            name: trimmedName,
            repoRoot: repoRoot,
            workspaceRoot: workspaceRoot,
            agentCommandTemplate: agentCommandTemplate?.isEmpty == false ? agentCommandTemplate! : "claude {{PROMPT}}",
            maxConcurrentAgents: maxConcurrent ?? 3
        )
        fleets[id] = FleetRuntimeState(
            config: config,
            isRunning: false,
            tasks: [:],
            taskIDByWorkspaceID: [:],
            currentAgentPIDByTaskID: [:],
            provisionGenerationByTaskID: [:],
            scheduledBackoffAttemptByTaskID: [:],
            scheduledStallAttemptByTaskID: [:]
        )
        persistSnapshot()
        notifyStateChanged()
        return .success(config)
    }

    /// Starts a Fleet.
    /// - Parameter id: The Fleet identifier.
    /// - Returns: `false` when no Fleet exists for `id`.
    @discardableResult
    public func startFleet(id: FleetID) -> Bool {
        guard var runtime = fleets[id] else { return false }
        runtime.isRunning = true
        fleets[id] = runtime
        persistSnapshot()
        notifyStateChanged()
        scheduleReconcileTimerIfNeeded()
        dispatchTick()
        return true
    }

    /// Stops a Fleet from dispatching new queued tasks.
    /// - Parameter id: The Fleet identifier.
    /// - Returns: `false` when no Fleet exists for `id`.
    @discardableResult
    public func stopFleet(id: FleetID) -> Bool {
        guard var runtime = fleets[id] else { return false }
        runtime.isRunning = false
        fleets[id] = runtime
        persistSnapshot()
        notifyStateChanged()
        if !anyFleetRunning {
            dependencies.timers.cancel(key: Self.reconcileTimerKey)
        }
        return true
    }

    /// Returns every Fleet configuration.
    public func fleetConfigs() -> [FleetConfig] {
        fleets.values.map(\.config).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns whether a Fleet is running.
    /// - Parameter id: The Fleet identifier.
    /// - Returns: `nil` when no Fleet exists for `id`.
    public func isFleetRunning(id: FleetID) -> Bool? {
        fleets[id]?.isRunning
    }

    /// Returns task counts keyed by state.
    /// - Parameter fleetID: The Fleet identifier.
    public func taskCounts(fleetID: FleetID) -> [FleetTaskState: Int] {
        guard let runtime = fleets[fleetID] else { return [:] }
        var counts: [FleetTaskState: Int] = [:]
        for state in FleetTaskState.allCases {
            counts[state] = 0
        }
        for task in runtime.tasks.values {
            counts[task.state, default: 0] += 1
        }
        return counts
    }

    /// Whether any Fleet is currently running.
    public var anyFleetRunning: Bool {
        fleets.values.contains(where: \.isRunning)
    }

    /// Adds a local task to a Fleet.
    /// - Parameters:
    ///   - fleetID: The Fleet identifier.
    ///   - title: The task title.
    ///   - body: The optional task body.
    ///   - priority: The optional scheduling priority.
    /// - Returns: The created task, or `.fleetNotFound`.
    public func addTask(
        fleetID: FleetID,
        title: String,
        body: String?,
        priority: Int?
    ) -> Result<FleetTask, FleetTaskAddError> {
        guard var runtime = fleets[fleetID] else { return .failure(.fleetNotFound) }
        let date = dependencies.now()
        let id = FleetTaskID("local:\(UUID().uuidString.lowercased())")
        let task = FleetTask(
            id: id,
            sourceKind: .local,
            key: id.rawValue,
            title: title,
            body: body ?? "",
            labels: [],
            priority: priority,
            sourceState: "open",
            createdAt: date,
            updatedAt: date,
            state: .queued,
            attempts: 0
        )
        runtime.tasks[id] = task
        fleets[fleetID] = runtime
        persistSnapshot()
        notifyStateChanged()
        if runtime.isRunning {
            dispatchTick()
        }
        return .success(task)
    }

    /// Lists tasks, optionally filtered by Fleet and state.
    /// - Parameters:
    ///   - fleetID: The optional Fleet identifier.
    ///   - state: The optional task state.
    /// - Returns: Matching tasks paired with their owning Fleet identifier.
    public func tasks(
        fleetID: FleetID?,
        state: FleetTaskState?
    ) -> Result<[(fleetID: FleetID, task: FleetTask)], FleetTaskAddError> {
        let fleetIDs: [FleetID]
        if let fleetID {
            guard fleets[fleetID] != nil else { return .failure(.fleetNotFound) }
            fleetIDs = [fleetID]
        } else {
            fleetIDs = Array(fleets.keys)
        }

        let rows = fleetIDs.flatMap { id in
            let values = fleets[id]?.tasks.values.map { $0 } ?? []
            return values.compactMap { task -> (FleetID, FleetTask)? in
                if let state, task.state != state {
                    return nil
                }
                return (id, task)
            }
        }.sorted { lhs, rhs in
            if lhs.1.updatedAt != rhs.1.updatedAt {
                return lhs.1.updatedAt > rhs.1.updatedAt
            }
            return lhs.1.id.rawValue < rhs.1.id.rawValue
        }
        return .success(rows)
    }

    /// Retries a task.
    /// - Parameter id: The task identifier.
    /// - Returns: The mutation outcome.
    public func retryTask(id: FleetTaskID) -> FleetTaskActionOutcome {
        userAction(id: id) { taskID, date in .userRetry(taskID: taskID, at: date) }
    }

    /// Cancels a task.
    /// - Parameter id: The task identifier.
    /// - Returns: The mutation outcome.
    public func cancelTask(id: FleetTaskID) -> FleetTaskActionOutcome {
        userAction(id: id) { taskID, date in .userCancel(taskID: taskID, at: date) }
    }

    /// Returns the workspace target for opening a task.
    /// - Parameter taskID: The task identifier.
    public func openTarget(taskID: FleetTaskID) -> FleetTaskOpenTarget {
        guard let located = locateTask(taskID) else { return .notFound }
        guard let workspaceID = located.task.workspaceID else { return .noWorkspace }
        return .workspace(workspaceID)
    }

    /// Returns whether the engine currently owns a task for a workspace.
    /// - Parameter workspaceID: The cmux workspace identifier.
    public func hasTask(workspaceID: String) -> Bool {
        locateTask(workspaceID: workspaceID) != nil
    }

    func runtimeConfig(for taskID: FleetTaskID) -> FleetConfig? {
        locateTask(taskID).map { fleets[$0.fleetID]?.config } ?? nil
    }

    func persistSnapshot() {
        let persisted = fleets
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { _, runtime in
                FleetPersistedFleet(
                    config: runtime.config,
                    isRunning: runtime.isRunning,
                    tasks: runtime.tasks.values.sorted { $0.id.rawValue < $1.id.rawValue }
                )
            }
        dependencies.persistence.save(FleetPersistedState(fleets: persisted))
    }

    func notifyStateChanged() {
        onStateChange?()
    }

    func restore() {
        guard let snapshot = dependencies.persistence.load() else { return }
        fleets.removeAll()
        for persisted in snapshot.fleets {
            var workspaceMap: [String: FleetTaskID] = [:]
            for task in persisted.tasks {
                if let workspaceID = task.workspaceID {
                    workspaceMap[workspaceID] = task.id
                }
            }
            fleets[persisted.config.id] = FleetRuntimeState(
                config: persisted.config,
                isRunning: false,
                tasks: Dictionary(uniqueKeysWithValues: persisted.tasks.map { ($0.id, $0) }),
                taskIDByWorkspaceID: workspaceMap,
                currentAgentPIDByTaskID: [:],
                provisionGenerationByTaskID: [:],
                scheduledBackoffAttemptByTaskID: [:],
                scheduledStallAttemptByTaskID: [:]
            )
        }
    }

    func locateTask(_ taskID: FleetTaskID) -> (fleetID: FleetID, task: FleetTask)? {
        for (fleetID, runtime) in fleets {
            if let task = runtime.tasks[taskID] {
                return (fleetID, task)
            }
        }
        return nil
    }

    func locateTask(workspaceID: String) -> (fleetID: FleetID, taskID: FleetTaskID, task: FleetTask)? {
        for (fleetID, runtime) in fleets {
            guard let taskID = runtime.taskIDByWorkspaceID[workspaceID],
                  let task = runtime.tasks[taskID]
            else { continue }
            return (fleetID, taskID, task)
        }
        return nil
    }

    private func userAction(
        id: FleetTaskID,
        signal: (FleetTaskID, Date) -> FleetSignal
    ) -> FleetTaskActionOutcome {
        guard let located = locateTask(id) else { return .notFound }
        let before = located.task
        apply(signal(id, dependencies.now()), to: id)
        guard let after = locateTask(id)?.task else { return .notFound }
        if after == before {
            return .invalidState(before.state)
        }
        notifyStateChanged()
        return .ok(after)
    }
}

/// Describes Fleet creation failures.
public enum FleetCreateError: Error, Equatable {
    /// The requested configuration is invalid.
    case invalidConfiguration(String)
}

/// Describes Fleet task-add failures.
public enum FleetTaskAddError: Error, Equatable {
    /// No Fleet exists for the requested identifier.
    case fleetNotFound
}

/// Describes a user task mutation outcome.
public enum FleetTaskActionOutcome: Equatable {
    /// The task mutation succeeded.
    case ok(FleetTask)

    /// No task exists for the requested identifier.
    case notFound

    /// The task exists but cannot be mutated from its current state.
    case invalidState(FleetTaskState)
}

/// Describes the task workspace target to open.
public enum FleetTaskOpenTarget: Equatable {
    /// The task has a workspace to open.
    case workspace(String)

    /// The task exists but has no workspace yet.
    case noWorkspace

    /// No task exists for the requested identifier.
    case notFound
}
