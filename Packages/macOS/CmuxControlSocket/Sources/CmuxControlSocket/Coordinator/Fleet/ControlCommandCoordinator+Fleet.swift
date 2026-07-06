internal import Foundation

/// The Fleet domain (`fleet.*`) owned by ``ControlCommandCoordinator``.
///
/// These commands are non-focus control-plane commands. `fleet.task.open`
/// returns the workspace ref minted by the coordinator's handle registry, but
/// this package layer does not activate the app or select/focus UI state.
extension ControlCommandCoordinator {
    /// Dispatches Fleet methods this coordinator owns.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a Fleet method.
    func handleFleet(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "fleet.list":
            return fleetList()
        case "fleet.create":
            return fleetCreate(request.params)
        case "fleet.start":
            return fleetStart(request.params)
        case "fleet.stop":
            return fleetStop(request.params)
        case "fleet.status":
            return fleetStatus(request.params)
        case "fleet.task.add":
            return fleetTaskAdd(request.params)
        case "fleet.task.list":
            return fleetTaskList(request.params)
        case "fleet.task.retry":
            return fleetTaskRetry(request.params)
        case "fleet.task.cancel":
            return fleetTaskCancel(request.params)
        case "fleet.task.open":
            return fleetTaskOpen(request.params)
        default:
            return nil
        }
    }

    /// `fleet.list` — list visible Fleets.
    func fleetList() -> ControlCallResult {
        let fleets = (context?.controlFleetList() ?? []).map(fleetPayload)
        return .ok(.object(["fleets": .array(fleets)]))
    }

    /// `fleet.status` — read Fleet engine status.
    func fleetStatus(_ params: [String: JSONValue]) -> ControlCallResult {
        let fleetID = string(params, "fleet_id")
        let resolution = context?.controlFleetStatus(fleetID: fleetID)
            ?? (fleetID.map { .fleetNotFound($0) } ?? .ok(ControlFleetStatusSnapshot(isRunning: false, fleets: [])))
        switch resolution {
        case .ok(let snapshot):
            return .ok(.object([
                "running": .bool(snapshot.isRunning),
                "fleets": .array(snapshot.fleets.map(fleetPayload)),
            ]))
        case .fleetNotFound(let id):
            return unknownFleetError(id)
        }
    }

    /// `fleet.create` — create a Fleet.
    func fleetCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return missingParam("name")
        }
        guard let repoRoot = string(params, "repo_root") else {
            return missingParam("repo_root")
        }
        let maxConcurrent: Int?
        if hasNonNull(params, "max_concurrent") {
            guard let parsed = int(params, "max_concurrent"), parsed >= 1 else {
                return .err(code: "invalid_params", message: "max_concurrent must be at least 1", data: nil)
            }
            maxConcurrent = parsed
        } else {
            maxConcurrent = nil
        }
        let inputs = ControlFleetCreateInputs(
            name: name,
            repoRoot: repoRoot,
            agentCommand: string(params, "agent_command"),
            maxConcurrent: maxConcurrent
        )
        let resolution = context?.controlFleetCreate(inputs: inputs) ?? .engineUnavailable
        switch resolution {
        case .created(let snapshot):
            return .ok(.object(["fleet": fleetPayload(snapshot)]))
        case .invalidConfiguration(let reason):
            return .err(code: "invalid_params", message: reason, data: nil)
        case .engineUnavailable:
            return engineUnavailableError()
        }
    }

    /// `fleet.start` — start a Fleet.
    func fleetStart(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let fleetID = string(params, "fleet_id") else {
            return missingParam("fleet_id")
        }
        let resolution = context?.controlFleetStart(fleetID: fleetID) ?? .engineUnavailable
        return fleetLifecycleResult(resolution)
    }

    /// `fleet.stop` — stop a Fleet.
    func fleetStop(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let fleetID = string(params, "fleet_id") else {
            return missingParam("fleet_id")
        }
        let resolution = context?.controlFleetStop(fleetID: fleetID) ?? .engineUnavailable
        return fleetLifecycleResult(resolution)
    }

    /// `fleet.task.add` — add a task to a Fleet.
    func fleetTaskAdd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let fleetID = string(params, "fleet_id") else {
            return missingParam("fleet_id")
        }
        guard let title = string(params, "title") else {
            return missingParam("title")
        }
        let inputs = ControlFleetTaskAddInputs(
            fleetID: fleetID,
            title: title,
            body: string(params, "body"),
            priority: hasNonNull(params, "priority") ? int(params, "priority") : nil
        )
        let resolution = context?.controlFleetTaskAdd(inputs: inputs) ?? .engineUnavailable
        switch resolution {
        case .added(let snapshot):
            return .ok(.object(["task": taskPayload(snapshot)]))
        case .fleetNotFound(let id):
            return unknownFleetError(id)
        case .engineUnavailable:
            return engineUnavailableError()
        }
    }

    /// `fleet.task.list` — list tasks with optional filters.
    func fleetTaskList(_ params: [String: JSONValue]) -> ControlCallResult {
        let fleetID = string(params, "fleet_id")
        let state: ControlFleetTaskStateName?
        if hasNonNull(params, "state") {
            guard let rawState = string(params, "state"),
                  let parsedState = ControlFleetTaskStateName(rawValue: rawState)
            else {
                return invalidStateFilterError()
            }
            state = parsedState
        } else {
            state = nil
        }

        let resolution = context?.controlFleetTaskList(fleetID: fleetID, state: state)
            ?? (fleetID.map { .fleetNotFound($0) } ?? .ok([]))
        switch resolution {
        case .ok(let tasks):
            return .ok(.object(["tasks": .array(tasks.map(taskPayload))]))
        case .fleetNotFound(let id):
            return unknownFleetError(id)
        }
    }

    /// `fleet.task.retry` — retry a task.
    func fleetTaskRetry(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let taskID = string(params, "task_id") else {
            return missingParam("task_id")
        }
        let resolution = context?.controlFleetTaskRetry(taskID: taskID) ?? .engineUnavailable
        return fleetTaskActionResult(resolution)
    }

    /// `fleet.task.cancel` — cancel a task.
    func fleetTaskCancel(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let taskID = string(params, "task_id") else {
            return missingParam("task_id")
        }
        let resolution = context?.controlFleetTaskCancel(taskID: taskID) ?? .engineUnavailable
        return fleetTaskActionResult(resolution)
    }

    /// `fleet.task.open` — open a task's workspace.
    func fleetTaskOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let taskID = string(params, "task_id") else {
            return missingParam("task_id")
        }
        let resolution = context?.controlFleetTaskOpen(taskID: taskID) ?? .engineUnavailable
        switch resolution {
        case .opened(let workspaceID):
            return .ok(.object([
                "task_id": .string(taskID),
                "workspace_id": ref(.workspace, workspaceID),
            ]))
        case .taskNotFound(let id):
            return unknownTaskError(id)
        case .workspaceUnavailable:
            return .err(code: "invalid_state", message: "task has no workspace yet", data: nil)
        case .engineUnavailable:
            return engineUnavailableError()
        }
    }

    /// Converts a Fleet snapshot to its wire payload.
    private func fleetPayload(_ snapshot: ControlFleetSnapshot) -> JSONValue {
        .object([
            "fleet_id": .string(snapshot.fleetID),
            "name": .string(snapshot.name),
            "repo_root": .string(snapshot.repoRoot),
            "running": .bool(snapshot.isRunning),
            "counts": fleetTaskCountsPayload(snapshot.taskCounts),
        ])
    }

    /// Converts task counts to a complete state-keyed object.
    private func fleetTaskCountsPayload(_ counts: [ControlFleetTaskStateName: Int]) -> JSONValue {
        var payload: [String: JSONValue] = [:]
        payload.reserveCapacity(ControlFleetTaskStateName.allCases.count)
        for state in ControlFleetTaskStateName.allCases {
            payload[state.rawValue] = .int(Int64(counts[state] ?? 0))
        }
        return .object(payload)
    }

    /// Converts a Fleet task snapshot to its wire payload.
    private func taskPayload(_ snapshot: ControlFleetTaskSnapshot) -> JSONValue {
        .object([
            "task_id": .string(snapshot.taskID),
            "fleet_id": .string(snapshot.fleetID),
            "source": .string(snapshot.source),
            "title": .string(snapshot.title),
            "state": .string(snapshot.state.rawValue),
            "blocked": .bool(snapshot.isBlocked),
            "attempts": .int(Int64(snapshot.attempts)),
            "priority": snapshot.priority.map { .int(Int64($0)) } ?? .null,
            "labels": .array(snapshot.labels.map { .string($0) }),
            "url": orNull(snapshot.url),
            "workspace_id": orNull(snapshot.workspaceID),
            "surface_id": orNull(snapshot.surfaceID),
            "directory": orNull(snapshot.directoryPath),
            "branch": orNull(snapshot.branch),
            "pr": pullRequestPayload(snapshot.pullRequest),
            "last_error": orNull(snapshot.lastError),
            "created_at": .double(snapshot.createdAt),
            "updated_at": .double(snapshot.updatedAt),
        ])
    }

    /// Converts pull-request metadata to its wire payload.
    private func pullRequestPayload(_ pullRequest: ControlFleetTaskPullRequest?) -> JSONValue {
        guard let pullRequest else { return .null }
        return .object([
            "url": orNull(pullRequest.url),
            "status": .string(pullRequest.status),
        ])
    }

    /// Maps lifecycle resolutions to Fleet wire results.
    private func fleetLifecycleResult(_ resolution: ControlFleetLifecycleResolution) -> ControlCallResult {
        switch resolution {
        case .ok(let snapshot):
            return .ok(.object(["fleet": fleetPayload(snapshot)]))
        case .fleetNotFound(let id):
            return unknownFleetError(id)
        case .engineUnavailable:
            return engineUnavailableError()
        }
    }

    /// Maps task action resolutions to Fleet wire results.
    private func fleetTaskActionResult(_ resolution: ControlFleetTaskActionResolution) -> ControlCallResult {
        switch resolution {
        case .ok(let snapshot):
            return .ok(.object(["task": taskPayload(snapshot)]))
        case .taskNotFound(let id):
            return unknownTaskError(id)
        case .invalidState(let current):
            return .err(code: "invalid_state", message: "task is in state \(current.rawValue)", data: nil)
        case .engineUnavailable:
            return engineUnavailableError()
        }
    }

    /// Builds an `invalid_params` error for a missing parameter.
    private func missingParam(_ key: String) -> ControlCallResult {
        .err(code: "invalid_params", message: "missing required parameter: \(key)", data: nil)
    }

    /// Builds the Fleet-engine unavailable error.
    private func engineUnavailableError() -> ControlCallResult {
        .err(code: "unavailable", message: "fleet engine is not available in this build", data: nil)
    }

    /// Builds an unknown-Fleet error.
    private func unknownFleetError(_ id: String) -> ControlCallResult {
        .err(code: "not_found", message: "unknown fleet: \(id)", data: nil)
    }

    /// Builds an unknown-task error.
    private func unknownTaskError(_ id: String) -> ControlCallResult {
        .err(code: "not_found", message: "unknown task: \(id)", data: nil)
    }

    /// Builds an invalid state-filter error listing valid wire values.
    private func invalidStateFilterError() -> ControlCallResult {
        let valid = ControlFleetTaskStateName.allCases.map(\.rawValue).joined(separator: ", ")
        return .err(code: "invalid_params", message: "state must be one of: \(valid)", data: nil)
    }
}
