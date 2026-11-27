import Foundation

actor AgentForkExecutableIdentityResolver {
    private let maxOutstandingResolutionWork = 16
    private var identityTasks: [String: Task<AgentForkSupport.ForkProbeExecutableIdentity?, Never>] = [:]
    private var validationResolutionTasks: [String: Task<AgentForkSupport.ForkValidationExecutableResolution, Never>] = [:]
    private var timedOutIdentityKeys = Set<String>()
    private var timedOutValidationResolutionKeys = Set<String>()

    func identityIfRunnable(
        probe: (executable: String, arguments: [String]),
        processEnvironment: [String: String],
        workingDirectory: String?,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
    ) async -> AgentForkSupport.ForkProbeExecutableIdentity? {
        let key = identityKey(
            probe: probe,
            processEnvironment: processEnvironment,
            workingDirectory: workingDirectory,
            probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
        )
        guard !timedOutIdentityKeys.contains(key) else {
            return nil
        }
        let task: Task<AgentForkSupport.ForkProbeExecutableIdentity?, Never>
        if let existing = identityTasks[key] {
            task = existing
        } else {
            guard outstandingResolutionWorkCount < maxOutstandingResolutionWork else {
                return nil
            }
            task = Task.detached(priority: .utility) {
                AgentForkSupport.forkProbeExecutableIdentityIfRunnable(
                    probe: probe,
                    processEnvironment: processEnvironment,
                    workingDirectory: workingDirectory,
                    probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing
                )
            }
            identityTasks[key] = task
            Task {
                _ = await task.value
                self.clearIdentityTask(for: key)
            }
        }
        return await boundedValue(
            task: task,
            timeoutValue: nil,
            onTimeout: { [weak self] in
                await self?.markIdentityTaskTimedOut(for: key)
            }
        )
    }

    func validationExecutableResolution(
        snapshot: SessionRestorableAgentSnapshot,
        isRemoteContext: Bool
    ) async -> AgentForkSupport.ForkValidationExecutableResolution {
        guard let resolutionWorkIdentity = AgentForkSupport.forkValidationExecutableResolutionWorkIdentity(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) else {
            return AgentForkSupport.forkValidationExecutableResolution(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
        }
        let key = "validation-resolution\u{1f}\(resolutionWorkIdentity)"
        guard !timedOutValidationResolutionKeys.contains(key) else {
            return ("unresolved", nil, nil, nil, [])
        }
        let task: Task<AgentForkSupport.ForkValidationExecutableResolution, Never>
        if let existing = validationResolutionTasks[key] {
            task = existing
        } else {
            guard outstandingResolutionWorkCount < maxOutstandingResolutionWork else {
                return ("unresolved", nil, nil, nil, [])
            }
            task = Task.detached(priority: .utility) {
                AgentForkSupport.forkValidationExecutableResolution(
                    snapshot: snapshot,
                    isRemoteContext: isRemoteContext
                )
            }
            validationResolutionTasks[key] = task
            Task {
                _ = await task.value
                self.clearValidationResolutionTask(for: key)
            }
        }
        return await boundedValue(
            task: task,
            timeoutValue: ("unresolved", nil, nil, nil, []),
            onTimeout: { [weak self] in
                await self?.markValidationResolutionTaskTimedOut(for: key)
            }
        )
    }

    private func clearIdentityTask(for key: String) {
        identityTasks[key] = nil
        timedOutIdentityKeys.remove(key)
    }

    private func clearValidationResolutionTask(for key: String) {
        validationResolutionTasks[key] = nil
        timedOutValidationResolutionKeys.remove(key)
    }

    private func markIdentityTaskTimedOut(for key: String) {
        guard identityTasks[key] != nil else { return }
        timedOutIdentityKeys.insert(key)
    }

    private func markValidationResolutionTaskTimedOut(for key: String) {
        guard validationResolutionTasks[key] != nil else { return }
        timedOutValidationResolutionKeys.insert(key)
    }

    private func boundedValue<Value>(
        task: Task<Value, Never>,
        timeoutValue: Value,
        onTimeout: @Sendable @escaping () async -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let gate = AgentForkTimeoutResumeGate(continuation)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(
                deadline: .now() + .nanoseconds(
                    Int(AgentForkSupport.executableIdentityResolutionTimeoutNanoseconds)
                )
            )
            timer.setEventHandler {
                timer.setEventHandler {}
                timer.cancel()
                let delivered = gate.resume(returning: timeoutValue)
                if delivered {
                    Task {
                        await onTimeout()
                    }
                }
            }
            timer.resume()
            Task.detached(priority: .utility) {
                let value = await task.value
                timer.setEventHandler {}
                timer.cancel()
                gate.resume(returning: value)
            }
        }
    }

    private var outstandingResolutionWorkCount: Int {
        identityTasks.count
            + validationResolutionTasks.count
    }

    private func identityKey(
        probe: (executable: String, arguments: [String]),
        processEnvironment: [String: String],
        workingDirectory: String?,
        probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing: Bool
    ) -> String {
        let environment = processEnvironment.keys.sorted().compactMap { key in
            processEnvironment[key].map { "\(key)=\($0)" }
        }
        return ([
            "defaultOnMissingCwd=\(probeFromDefaultDirectoryWhenWorkingDirectoryIsMissing)",
            probe.executable,
            "cwd=\(workingDirectory ?? "")",
        ] + probe.arguments + environment).joined(separator: "\u{1f}")
    }
}
