import CmuxControlSocket
import CmuxFleet
import Foundation

/// The Fleet-domain witnesses bridge the control socket to the app-owned Fleet engine.
extension TerminalController: ControlFleetContext {
    func controlFleetList() -> [ControlFleetSnapshot] {
        let engine = FleetAppHost.shared.engine
        return engine.fleetConfigs().map { config in
            FleetControlSocketMapping.fleetSnapshot(
                config: config,
                counts: engine.taskCounts(fleetID: config.id),
                isRunning: engine.isFleetRunning(id: config.id) ?? false
            )
        }
    }

    func controlFleetStatus(fleetID: String?) -> ControlFleetStatusResolution {
        let engine = FleetAppHost.shared.engine
        if let fleetID {
            let id = FleetID(fleetID)
            guard let isRunning = engine.isFleetRunning(id: id),
                  let config = engine.fleetConfigs().first(where: { $0.id == id })
            else { return .fleetNotFound(fleetID) }
            return .ok(ControlFleetStatusSnapshot(isRunning: isRunning, fleets: [
                FleetControlSocketMapping.fleetSnapshot(
                    config: config,
                    counts: engine.taskCounts(fleetID: id),
                    isRunning: isRunning
                ),
            ]))
        }
        return .ok(ControlFleetStatusSnapshot(isRunning: engine.anyFleetRunning, fleets: controlFleetList()))
    }

    func controlFleetCreate(inputs: ControlFleetCreateInputs) -> ControlFleetCreateResolution {
        let engine = FleetAppHost.shared.engine
        switch engine.createFleet(
            name: inputs.name,
            repoRoot: inputs.repoRoot,
            agentCommandTemplate: inputs.agentCommand,
            maxConcurrent: inputs.maxConcurrent
        ) {
        case .success(let config):
            return .created(snapshot(config: config, engine: engine))
        case .failure(.invalidConfiguration(let reason)):
            return .invalidConfiguration(reason: reason)
        }
    }

    func controlFleetStart(fleetID: String) -> ControlFleetLifecycleResolution {
        let engine = FleetAppHost.shared.engine
        let id = FleetID(fleetID)
        guard engine.startFleet(id: id),
              let config = engine.fleetConfigs().first(where: { $0.id == id })
        else { return .fleetNotFound(fleetID) }
        return .ok(snapshot(config: config, engine: engine))
    }

    func controlFleetStop(fleetID: String) -> ControlFleetLifecycleResolution {
        let engine = FleetAppHost.shared.engine
        let id = FleetID(fleetID)
        guard engine.stopFleet(id: id),
              let config = engine.fleetConfigs().first(where: { $0.id == id })
        else { return .fleetNotFound(fleetID) }
        return .ok(snapshot(config: config, engine: engine))
    }

    func controlFleetTaskAdd(inputs: ControlFleetTaskAddInputs) -> ControlFleetTaskAddResolution {
        let engine = FleetAppHost.shared.engine
        let id = FleetID(inputs.fleetID)
        switch engine.addTask(
            fleetID: id,
            title: inputs.title,
            body: inputs.body,
            priority: inputs.priority
        ) {
        case .success(let task):
            return .added(FleetControlSocketMapping.taskSnapshot(fleetID: id, task: task))
        case .failure(.fleetNotFound):
            return .fleetNotFound(inputs.fleetID)
        }
    }

    func controlFleetTaskList(
        fleetID: String?,
        state: ControlFleetTaskStateName?
    ) -> ControlFleetTaskListResolution {
        let engine = FleetAppHost.shared.engine
        let fleetIDValue = fleetID.map(FleetID.init)
        switch engine.tasks(
            fleetID: fleetIDValue,
            state: state.map(FleetControlSocketMapping.state)
        ) {
        case .success(let rows):
            return .ok(rows.map { FleetControlSocketMapping.taskSnapshot(fleetID: $0.fleetID, task: $0.task) })
        case .failure(.fleetNotFound):
            return .fleetNotFound(fleetID ?? "")
        }
    }

    func controlFleetTaskRetry(taskID: String) -> ControlFleetTaskActionResolution {
        taskActionResolution(
            FleetAppHost.shared.engine.retryTask(id: FleetTaskID(taskID)),
            requestedTaskID: taskID
        )
    }

    func controlFleetTaskCancel(taskID: String) -> ControlFleetTaskActionResolution {
        taskActionResolution(
            FleetAppHost.shared.engine.cancelTask(id: FleetTaskID(taskID)),
            requestedTaskID: taskID
        )
    }

    func controlFleetTaskOpen(taskID: String) -> ControlFleetTaskOpenResolution {
        let engine = FleetAppHost.shared.engine
        switch engine.openTarget(taskID: FleetTaskID(taskID)) {
        case .workspace(let idString):
            guard let workspaceID = UUID(uuidString: idString),
                  let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceID })
            else { return .workspaceUnavailable }
            if let windowID = AppDelegate.shared?.windowId(for: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            TerminalController.shared.setActiveTabManager(tabManager)
            return .opened(workspaceID: workspaceID)
        case .noWorkspace:
            return .workspaceUnavailable
        case .notFound:
            return .taskNotFound(taskID)
        }
    }

    private func snapshot(config: FleetConfig, engine: FleetEngine) -> ControlFleetSnapshot {
        FleetControlSocketMapping.fleetSnapshot(
            config: config,
            counts: engine.taskCounts(fleetID: config.id),
            isRunning: engine.isFleetRunning(id: config.id) ?? false
        )
    }

    private func taskActionResolution(
        _ outcome: FleetTaskActionOutcome,
        requestedTaskID: String
    ) -> ControlFleetTaskActionResolution {
        switch outcome {
        case .ok(let task):
            let rows = try? FleetAppHost.shared.engine.tasks(fleetID: nil, state: nil).get()
            guard let row = rows?.first(where: { $0.task.id == task.id })
            else { return .taskNotFound(task.id.rawValue) }
            return .ok(FleetControlSocketMapping.taskSnapshot(fleetID: row.fleetID, task: task))
        case .notFound:
            return .taskNotFound(requestedTaskID)
        case .invalidState(let state):
            return .invalidState(current: FleetControlSocketMapping.state(state))
        }
    }
}
