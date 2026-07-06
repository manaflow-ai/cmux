public import Foundation

extension FleetEngine {
    static let reconcileTimerKey = "reconcile"

    /// Ingests a workstream hook for a Fleet-managed workspace.
    /// - Parameters:
    ///   - workspaceID: The cmux workspace identifier.
    ///   - sessionID: The agent session identifier, when known.
    ///   - pid: The agent process identifier, when known.
    ///   - kind: The hook kind.
    ///   - at: The hook timestamp.
    public func noteWorkstreamHook(
        workspaceID: String,
        sessionID: String?,
        pid: Int32?,
        kind: FleetHookKind,
        at: Date
    ) {
        guard let located = locateTask(workspaceID: workspaceID),
              !located.task.state.isTerminal
        else { return }
        let taskID = located.taskID
        let attempt = located.task.attempts

        switch kind {
        case .sessionStart:
            if let pid {
                let watchedAttempt = attempt
                fleets[located.fleetID]?.currentAgentPIDByTaskID[taskID] = pid
                dependencies.processWatcher.watchExit(pid: pid) { [weak self] in
                    guard let self else { return }
                    self.apply(.pidExited(taskID: taskID, attempt: watchedAttempt, at: self.dependencies.now()), to: taskID)
                }
            }
            apply(.agentSessionStarted(
                taskID: taskID,
                attempt: attempt,
                sessionID: sessionID ?? "",
                pid: pid,
                at: at
            ), to: taskID)
        case .blockingRequest:
            apply(.blockingItemReceived(taskID: taskID, attempt: attempt, at: at), to: taskID)
        case .promptSubmit, .toolUse:
            if locateTask(taskID)?.task.state == .needsInput {
                apply(.blockingItemResolved(taskID: taskID, attempt: attempt, at: at), to: taskID)
            }
            apply(.activity(taskID: taskID, attempt: attempt, at: at), to: taskID)
        case .stop, .notification, .other:
            apply(.activity(taskID: taskID, attempt: attempt, at: at), to: taskID)
        case .sessionEnd:
            apply(.agentStopped(taskID: taskID, attempt: attempt, at: at), to: taskID)
        }
    }

    func apply(_ signal: FleetSignal, to taskID: FleetTaskID) {
        guard let located = locateTask(taskID),
              var runtime = fleets[located.fleetID],
              let task = runtime.tasks[taskID]
        else { return }

        let supervisor = FleetSupervisor(config: runtime.config.supervision)
        let (next, commands) = supervisor.reduce(task: task, signal: signal)
        dependencies.debugLog("fleet.engine.signal task=\(taskID.rawValue) signal=\(signal)")
        guard next != task || !commands.isEmpty else { return }

        runtime.tasks[taskID] = next
        if let workspaceID = next.workspaceID {
            runtime.taskIDByWorkspaceID[workspaceID] = taskID
        }
        if task.attempts != next.attempts {
            runtime.currentAgentPIDByTaskID.removeValue(forKey: taskID)
        }
        fleets[located.fleetID] = runtime

        updateStallTimer(previous: task, current: next)
        for command in commands {
            execute(command, fleetID: located.fleetID)
        }
        if next != task {
            persistSnapshot()
        }
        if task.state != next.state {
            dispatchTick()
        }
    }

    func dispatchTick() {
        let selections: [(FleetID, FleetTaskID)] = fleets.compactMap { fleetID, runtime -> [(FleetID, FleetTaskID)]? in
            guard runtime.isRunning else { return nil }
            let selected = FleetScheduler(
                maxConcurrentAgents: runtime.config.maxConcurrentAgents,
                provisioningCap: runtime.config.provisioningCap
            ).dispatch(Array(runtime.tasks.values))
            return selected.map { (fleetID, $0.id) }
        }.flatMap { $0 }

        for (fleetID, taskID) in selections {
            guard fleets[fleetID]?.tasks[taskID]?.state == .queued else { continue }
            apply(.dispatched(taskID: taskID, at: dependencies.now()), to: taskID)
        }
    }

    func reconcilePass() {
        for (fleetID, runtime) in fleets {
            for task in runtime.tasks.values where Self.reconcileProbes(task.state) {
                guard let workspaceID = task.workspaceID else { continue }
                if !task.state.isTerminal, !dependencies.world.workspaceExists(workspaceID: workspaceID) {
                    apply(.workspaceClosed(taskID: task.id, at: dependencies.now()), to: task.id)
                    continue
                }
                if let pr = dependencies.world.pullRequestStatus(
                    workspaceID: workspaceID,
                    directoryPath: task.directoryPath,
                    branch: task.branch
                ), pr.url != task.pr?.url || pr.state != task.pr?.state {
                    apply(.prChanged(taskID: task.id, pr: pr, at: dependencies.now()), to: task.id)
                    continue
                }
                guard task.state == .running,
                      let lastActivityAt = task.lastActivityAt,
                      let surfaceID = task.surfaceID,
                      dependencies.now().timeIntervalSince(lastActivityAt) * 1_000 > Double(dependencies.promptIdleGraceMS),
                      dependencies.world.isShellPromptIdle(workspaceID: workspaceID, surfaceID: surfaceID) == true
                else { continue }
                apply(.promptIdleObserved(taskID: task.id, attempt: task.attempts, at: dependencies.now()), to: task.id)
            }
            _ = fleetID
        }
        persistSnapshot()
        dispatchTick()
        scheduleReconcileTimerIfNeeded()
    }

    func scheduleReconcileTimerIfNeeded() {
        guard anyFleetRunning else { return }
        dependencies.timers.schedule(key: Self.reconcileTimerKey, delayMS: dependencies.reconcileIntervalMS) { [weak self] in
            self?.reconcilePass()
        }
    }

    private func updateStallTimer(previous: FleetTask, current: FleetTask) {
        if Self.hasStallTimer(previous.state),
           (!Self.hasStallTimer(current.state) || previous.attempts != current.attempts),
           let attempt = fleets.values.compactMap({ $0.scheduledStallAttemptByTaskID[previous.id] }).first {
            dependencies.timers.cancel(key: stallKey(taskID: previous.id, attempt: attempt))
            removeScheduledStallAttempt(taskID: previous.id)
        }

        guard Self.hasStallTimer(current.state),
              let config = runtimeConfig(for: current.id)
        else { return }
        dependencies.timers.cancel(key: stallKey(taskID: current.id, attempt: current.attempts))
        setScheduledStallAttempt(current.attempts, taskID: current.id)
        dependencies.timers.schedule(
            key: stallKey(taskID: current.id, attempt: current.attempts),
            delayMS: config.supervision.stallTimeoutMS
        ) { [weak self] in
            guard let self else { return }
            self.apply(
                .stallTimeout(taskID: current.id, attempt: current.attempts, at: self.dependencies.now()),
                to: current.id
            )
        }
    }

    private func setScheduledStallAttempt(_ attempt: Int, taskID: FleetTaskID) {
        for fleetID in fleets.keys where fleets[fleetID]?.tasks[taskID] != nil {
            fleets[fleetID]?.scheduledStallAttemptByTaskID[taskID] = attempt
        }
    }

    private func removeScheduledStallAttempt(taskID: FleetTaskID) {
        for fleetID in fleets.keys {
            fleets[fleetID]?.scheduledStallAttemptByTaskID.removeValue(forKey: taskID)
        }
    }

    private func stallKey(taskID: FleetTaskID, attempt: Int) -> String {
        "stall:\(taskID.rawValue):\(attempt)"
    }

    private static func hasStallTimer(_ state: FleetTaskState) -> Bool {
        switch state {
        case .launching, .running, .needsInput:
            true
        case .queued, .provisioning, .stalled, .retryBackoff, .awaitingReview, .done, .failed, .cancelled:
            false
        }
    }

    /// Returns whether reconcile still watches a task in the given state.
    ///
    /// `.failed` stays probed for pull-request changes so an open or merged PR
    /// can rescue the task to `.awaitingReview`/`.done` even when it failed
    /// before the PR badge populated. `.done`/`.cancelled` never change again.
    private static func reconcileProbes(_ state: FleetTaskState) -> Bool {
        switch state {
        case .done, .cancelled:
            false
        case .queued, .provisioning, .launching, .running, .needsInput, .stalled,
             .retryBackoff, .awaitingReview, .failed:
            true
        }
    }
}
