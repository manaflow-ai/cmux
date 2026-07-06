import Foundation

extension FleetEngine {
    func execute(_ command: FleetCommand, fleetID: FleetID) {
        switch command {
        case .provisionWorkspace(let task):
            provisionWorkspace(task, fleetID: fleetID)
        case .launchAgent(let task, _), .resendAgentCommand(let task, _):
            sendAgentCommand(for: task)
        case .killAgent(let task):
            killAgent(for: task)
        case .scheduleBackoff(let taskID, let attempt, let delayMS):
            scheduleBackoff(taskID: taskID, attempt: attempt, delayMS: delayMS)
        case .cancelBackoff(let taskID):
            cancelBackoff(taskID: taskID)
        case .postNotification(let taskID, let kind):
            postNotification(taskID: taskID, kind: kind)
        case .cleanupWorkspace(let task):
            if let workspaceID = task.workspaceID {
                dependencies.actuator.closeWorkspace(workspaceID: workspaceID)
            }
        case .persistSnapshot:
            persistSnapshot()
        case .none:
            break
        }
    }

    private func provisionWorkspace(_ task: FleetTask, fleetID: FleetID) {
        guard var runtime = fleets[fleetID] else { return }
        if let workspaceID = task.workspaceID,
           task.surfaceID != nil,
           let directoryPath = task.directoryPath,
           dependencies.world.workspaceExists(workspaceID: workspaceID) {
            // Reuse the prior attempt's live workspace instead of provisioning a duplicate.
            apply(.provisioned(taskID: task.id, path: directoryPath, isBrandNew: false, at: dependencies.now()), to: task.id)
            return
        }
        let config = runtime.config
        let generation = (runtime.provisionGenerationByTaskID[task.id] ?? 0) + 1
        runtime.provisionGenerationByTaskID[task.id] = generation
        fleets[fleetID] = runtime
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.dependencies.actuator.provisionWorkspace(task: task, fleet: config)
            switch result {
            case .success(let outcome):
                guard var runtime = self.fleets[fleetID],
                      var current = runtime.tasks[task.id],
                      current.state == .provisioning,
                      runtime.provisionGenerationByTaskID[task.id] == generation
                else {
                    self.dependencies.actuator.closeWorkspace(workspaceID: outcome.workspaceID)
                    return
                }
                runtime.provisionGenerationByTaskID.removeValue(forKey: task.id)
                if let previousWorkspaceID = current.workspaceID,
                   previousWorkspaceID != outcome.workspaceID,
                   runtime.taskIDByWorkspaceID[previousWorkspaceID] == task.id {
                    // The replaced workspace is gone; stale hooks from it must not bind.
                    runtime.taskIDByWorkspaceID.removeValue(forKey: previousWorkspaceID)
                }
                current.workspaceID = outcome.workspaceID
                current.surfaceID = outcome.surfaceID
                current.directoryPath = outcome.directoryPath
                current.branch = outcome.branch
                runtime.tasks[task.id] = current
                runtime.taskIDByWorkspaceID[outcome.workspaceID] = task.id
                self.fleets[fleetID] = runtime
                self.apply(
                    .provisioned(
                        taskID: task.id,
                        path: outcome.directoryPath,
                        isBrandNew: outcome.isBrandNew,
                        at: self.dependencies.now()
                    ),
                    to: task.id
                )
            case .failure(let error):
                guard var runtime = self.fleets[fleetID],
                      runtime.tasks[task.id]?.state == .provisioning,
                      runtime.provisionGenerationByTaskID[task.id] == generation
                else { return }
                runtime.provisionGenerationByTaskID.removeValue(forKey: task.id)
                self.fleets[fleetID] = runtime
                self.apply(
                    .provisionFailed(taskID: task.id, message: error.message, at: self.dependencies.now()),
                    to: task.id
                )
            }
        }
    }

    private func sendAgentCommand(for task: FleetTask) {
        guard let located = locateTask(task.id)?.task,
              let config = runtimeConfig(for: task.id),
              let workspaceID = located.workspaceID,
              let surfaceID = located.surfaceID
        else { return }
        let rendered = FleetPromptTemplate().render(
            template: config.agentCommandTemplate,
            task: located,
            directory: located.directoryPath ?? "",
            branch: located.branch
        )
        let didSend = dependencies.actuator.sendAgentCommand(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            text: rendered + "\n"
        )
        if !didSend {
            apply(.pidExited(taskID: located.id, attempt: located.attempts, at: dependencies.now()), to: located.id)
        }
    }

    private func killAgent(for task: FleetTask) {
        guard let located = locateTask(task.id),
              let workspaceID = located.task.workspaceID,
              let surfaceID = located.task.surfaceID
        else { return }
        let pid = fleets[located.fleetID]?.currentAgentPIDByTaskID[task.id]
        dependencies.actuator.killAgent(workspaceID: workspaceID, surfaceID: surfaceID, pid: pid)
    }

    private func scheduleBackoff(taskID: FleetTaskID, attempt: Int, delayMS: Int) {
        guard let located = locateTask(taskID) else { return }
        fleets[located.fleetID]?.scheduledBackoffAttemptByTaskID[taskID] = attempt
        dependencies.timers.schedule(key: backoffKey(taskID: taskID, attempt: attempt), delayMS: delayMS) { [weak self] in
            guard let self else { return }
            self.apply(.backoffElapsed(taskID: taskID, attempt: attempt, at: self.dependencies.now()), to: taskID)
        }
    }

    private func cancelBackoff(taskID: FleetTaskID) {
        guard let located = locateTask(taskID),
              let attempt = fleets[located.fleetID]?.scheduledBackoffAttemptByTaskID.removeValue(forKey: taskID)
        else { return }
        dependencies.timers.cancel(key: backoffKey(taskID: taskID, attempt: attempt))
    }

    private func postNotification(taskID: FleetTaskID, kind: FleetNotificationKind) {
        guard let located = locateTask(taskID),
              let config = fleets[located.fleetID]?.config
        else { return }
        dependencies.actuator.postNotification(fleet: config, task: located.task, kind: kind)
    }

    private func backoffKey(taskID: FleetTaskID, attempt: Int) -> String {
        "backoff:\(taskID.rawValue):\(attempt)"
    }
}
