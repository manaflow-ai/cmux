import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func enqueueToolOperation(
        lane: SimulatorToolOperationLane,
        requestIdentifier: UUID,
        timeout: Duration,
        body: @escaping @MainActor @Sendable (SimulatorWorkerCoordinator, UUID) async -> Void
    ) {
        guard !cancelingToolOperationLanes.contains(lane) else {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "worker_operation_cancelling",
                    message: String(
                        localized: "simulator.failure.workerOperationCancelling",
                        defaultValue: "The previous Simulator tool operation is still stopping."
                    ),
                    isRecoverable: true
                )
            ))
            return
        }
        let outstandingCount = toolOperationQueues[lane, default: []].count
            + (toolOperationTasks[lane] == nil ? 0 : 1)
        guard outstandingCount < SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
        else {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "worker_operation_busy",
                    message: String(
                        localized: "simulator.failure.workerOperationQueueBusy",
                        defaultValue: "The isolated Simulator tool queue is at capacity."
                    ),
                    isRecoverable: true
                )
            ))
            return
        }
        toolOperationQueues[lane, default: []].append(SimulatorQueuedToolOperation(
            requestIdentifier: requestIdentifier,
            timeout: timeout,
            body: body
        ))
        startNextToolOperationIfNeeded(in: lane)
    }

    func toolOperationIsCurrent(_ generation: UUID) -> Bool {
        toolOperationGenerations.values.contains(generation)
            && !timedOutToolOperationGenerations.contains(generation)
            && !Task.isCancelled
    }

    func toolOperationDidCommit(_ generation: UUID) -> Bool {
        guard toolOperationGenerations.values.contains(generation) else { return false }
        committedToolOperationGenerations.insert(generation)
        return true
    }

    func cancelToolOperations() async {
        let activeLanes = Set(toolOperationTasks.keys)
        let tasks = Array(toolOperationTasks.values)
        failQueuedToolOperations()
        toolOperationQueues.removeAll()
        toolOperationDeadlineTasks.values.forEach { $0.cancel() }
        toolOperationDeadlineTasks.removeAll()
        toolOperationCancellationGraceTasks.values.forEach { $0.cancel() }
        toolOperationCancellationGraceTasks.removeAll()
        timedOutToolOperationGenerations.removeAll()
        cancelingToolOperationLanes.formUnion(activeLanes)
        tasks.forEach { $0.cancel() }
        guard await toolOperationsDrainBeforeCancellationGrace(tasks) else {
            toolOperationContainment.terminate()
            return
        }
        toolOperationTasks.removeAll()
        cancelingToolOperationLanes.removeAll()
    }

    func cancelToolOperationsWithoutWaiting() {
        failQueuedToolOperations()
        toolOperationQueues.removeAll()
        toolOperationDeadlineTasks.values.forEach { $0.cancel() }
        toolOperationDeadlineTasks.removeAll()
        toolOperationCancellationGraceTasks.values.forEach { $0.cancel() }
        toolOperationCancellationGraceTasks.removeAll()
        timedOutToolOperationGenerations.removeAll()
        cancelingToolOperationLanes.formUnion(toolOperationTasks.keys)
        toolOperationTasks.values.forEach { $0.cancel() }
    }

    private func startNextToolOperationIfNeeded(in lane: SimulatorToolOperationLane) {
        guard toolOperationTasks[lane] == nil,
              var queue = toolOperationQueues[lane],
              !queue.isEmpty else { return }
        let operation = queue.removeFirst()
        toolOperationQueues[lane] = queue
        let generation = UUID()
        toolOperationGenerations[lane] = generation
        toolOperationCurrentRequestIdentifiers[lane] = operation.requestIdentifier
        toolOperationTasks[lane] = Task { @MainActor [weak self] in
            guard let self else { return }
            let sleeper = self.toolOperationSleeper
            let deadlineTask = Task { @MainActor [weak self] in
                do {
                    try await sleeper.sleep(for: operation.timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.toolOperationDeadlineExpired(
                    lane: lane,
                    generation: generation
                )
            }
            self.toolOperationDeadlineTasks[lane] = deadlineTask
            await operation.body(self, generation)
            deadlineTask.cancel()
            self.toolOperationDeadlineTasks.removeValue(forKey: lane)
            self.toolOperationCancellationGraceTasks.removeValue(forKey: lane)?.cancel()
            if self.cancelingToolOperationLanes.remove(lane) != nil {
                if !self.committedToolOperationGenerations.contains(generation),
                   let requestIdentifier = self.toolOperationCurrentRequestIdentifiers[lane] {
                    self.sendToolOperationCancellation(requestIdentifier: requestIdentifier)
                }
                self.timedOutToolOperationGenerations.remove(generation)
                self.committedToolOperationGenerations.remove(generation)
                self.toolOperationGenerations.removeValue(forKey: lane)
                self.toolOperationTasks.removeValue(forKey: lane)
                self.toolOperationCurrentRequestIdentifiers.removeValue(forKey: lane)
                self.startNextToolOperationIfNeeded(in: lane)
                return
            }
            guard self.toolOperationGenerations[lane] == generation else {
                self.timedOutToolOperationGenerations.remove(generation)
                self.committedToolOperationGenerations.remove(generation)
                self.toolOperationTasks.removeValue(forKey: lane)
                self.toolOperationCurrentRequestIdentifiers.removeValue(forKey: lane)
                return
            }
            if self.timedOutToolOperationGenerations.contains(generation),
               !self.committedToolOperationGenerations.contains(generation) {
                self.sendToolOperationTimeout(requestIdentifier: operation.requestIdentifier)
            }
            self.timedOutToolOperationGenerations.remove(generation)
            self.committedToolOperationGenerations.remove(generation)
            self.toolOperationGenerations.removeValue(forKey: lane)
            self.toolOperationTasks.removeValue(forKey: lane)
            self.toolOperationCurrentRequestIdentifiers.removeValue(forKey: lane)
            self.startNextToolOperationIfNeeded(in: lane)
        }
    }

    private func toolOperationDeadlineExpired(
        lane: SimulatorToolOperationLane,
        generation: UUID
    ) {
        guard toolOperationGenerations[lane] == generation else { return }
        timedOutToolOperationGenerations.insert(generation)
        toolOperationTasks[lane]?.cancel()
        let sleeper = toolOperationSleeper
        let containment = toolOperationContainment
        toolOperationCancellationGraceTasks[lane]?.cancel()
        toolOperationCancellationGraceTasks[lane] = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(for: containment.cancellationGrace)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.toolOperationGenerations[lane] == generation,
                  self.toolOperationTasks[lane] != nil
            else { return }
            containment.terminate()
        }
    }

    private func sendToolOperationTimeout(requestIdentifier: UUID) {
        send(.requestFailure(
            requestID: requestIdentifier,
            SimulatorFailure(
                code: "worker_operation_timed_out",
                message: String(
                    localized: "simulator.failure.workerOperationTimedOut",
                    defaultValue: "The Simulator tool operation exceeded its bounded deadline."
                ),
                isRecoverable: true
            )
        ))
    }

    private func failQueuedToolOperations() {
        for requestIdentifier in toolOperationQueues.values.flatMap({
            $0.map(\.requestIdentifier)
        }) {
            sendToolOperationCancellation(requestIdentifier: requestIdentifier)
        }
    }

    private func sendToolOperationCancellation(requestIdentifier: UUID) {
        send(.requestFailure(
            requestID: requestIdentifier,
            SimulatorFailure(
                code: "worker_operation_cancelled",
                message: String(
                    localized: "simulator.failure.workerOperationCancelled",
                    defaultValue: "The Simulator changed while this tool operation was running."
                ),
                isRecoverable: true
            )
        ))
    }

    private func toolOperationsDrainBeforeCancellationGrace(
        _ tasks: [Task<Void, Never>]
    ) async -> Bool {
        guard !tasks.isEmpty else { return true }
        let (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let completionTask = Task {
            for task in tasks { await task.value }
            continuation.yield(true)
        }
        let sleeper = toolOperationSleeper
        let grace = toolOperationContainment.cancellationGrace
        let graceTask = Task {
            do {
                try await sleeper.sleep(for: grace)
            } catch {
                return
            }
            continuation.yield(false)
        }
        var iterator = stream.makeAsyncIterator()
        let drained = await iterator.next() ?? false
        continuation.finish()
        completionTask.cancel()
        graceTask.cancel()
        return drained
    }

    func configureCamera(
        requestIdentifier: UUID,
        configuration: SimulatorCameraConfiguration,
        operationGeneration: UUID
    ) async {
        var succeeded = false
        var resolvedTargetBundleIdentifier: String?
        do {
            let inferredApplication: SimulatorApplicationInfo?
            if configuration.targetBundleIdentifier == nil {
                inferredApplication = try await accessibilityExecutor.foregroundApplication()
            } else {
                inferredApplication = nil
            }
            let application = try await camera.configure(
                configuration,
                inferredApplication: inferredApplication,
                targetResolved: { [weak self] bundleIdentifier in
                    guard let self else { throw CancellationError() }
                    try await self.transferCameraTargetCleanupOwnership(
                        requestIdentifier: requestIdentifier,
                        bundleIdentifier: bundleIdentifier
                    )
                },
                operationIsCurrent: { [weak self] in
                    self?.toolOperationIsCurrent(operationGeneration) == true
                }
            )
            guard toolOperationDidCommit(operationGeneration) else { return }
            succeeded = true
            let target = application?.bundleIdentifier
                ?? configuration.targetBundleIdentifier
                ?? inferredApplication?.bundleIdentifier
                ?? "disabled"
            resolvedTargetBundleIdentifier = target == "disabled" ? nil : target
            let pid = application?.processIdentifier.map(String.init) ?? "unknown"
            emitAction("camera", summary: "\(target):\(pid)", succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error)
            emitAction("camera", summary: error.localizedDescription, succeeded: false)
        }
        send(.cameraConfiguration(
            requestID: requestIdentifier,
            succeeded: succeeded,
            targetBundleIdentifier: resolvedTargetBundleIdentifier
        ))
    }

    func transferCameraTargetCleanupOwnership(
        requestIdentifier: UUID,
        bundleIdentifier: String
    ) async throws {
        guard send(.cameraTargetResolved(
            requestID: requestIdentifier,
            bundleIdentifier: bundleIdentifier
        )) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.cameraConfigurationFailed",
                    defaultValue: "The isolated worker could not configure the requested camera source and target."
                )
            )
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingCameraTargetAcknowledgements[requestIdentifier] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCameraTargetCleanupTransfer(requestIdentifier)
            }
        }
    }

    func cancelCameraTargetCleanupTransfer(_ requestIdentifier: UUID) {
        pendingCameraTargetAcknowledgements
            .removeValue(forKey: requestIdentifier)?
            .resume(throwing: CancellationError())
    }

    func switchCameraSource(
        requestIdentifier: UUID,
        configuration: SimulatorCameraConfiguration,
        operationGeneration: UUID
    ) async {
        var succeeded = false
        do {
            try await camera.switchSource(configuration)
            guard toolOperationDidCommit(operationGeneration) else { return }
            succeeded = true
            emitAction("camera_source", summary: "switched", succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error)
            emitAction("camera_source", summary: error.localizedDescription, succeeded: false)
        }
        send(.cameraConfiguration(
            requestID: requestIdentifier,
            succeeded: succeeded,
            targetBundleIdentifier: nil
        ))
    }

    func prepareApplicationMutation(
        requestIdentifier: UUID,
        bundleIdentifier: String,
        operationGeneration: UUID
    ) async {
        do {
            try await webInspector.releaseSession(ifOwnedBy: bundleIdentifier)
            await camera.prepareForIntentionalApplicationMutation(
                bundleIdentifier: bundleIdentifier
            )
            guard toolOperationDidCommit(operationGeneration) else { return }
            send(.applicationMutationPrepared(requestID: requestIdentifier, succeeded: true))
            emitAction(
                "application_mutation",
                summary: bundleIdentifier,
                succeeded: true
            )
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error)
            send(.applicationMutationPrepared(requestID: requestIdentifier, succeeded: false))
            emitAction(
                "application_mutation",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func setPrivateInterface(
        requestIdentifier: UUID,
        deviceIdentifier: String,
        setting: SimulatorInterfaceSetting,
        operationGeneration: UUID
    ) async {
        var succeeded = false
        do {
            guard currentDeviceIdentifier == deviceIdentifier else {
                throw SimulatorWorkerFailure.deviceNotFound(
                    "The interface-settings target does not match the attached Simulator."
                )
            }
            try await mutationGate.withLocks([
                .interface(deviceIdentifier: deviceIdentifier),
            ]) {
                try await interfaceSettings.set(
                    deviceIdentifier: deviceIdentifier,
                    setting: setting
                )
            }
            guard toolOperationDidCommit(operationGeneration) else { return }
            succeeded = true
            emitAction("private_interface", summary: String(describing: setting), succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error)
            emitAction("private_interface", summary: error.localizedDescription, succeeded: false)
        }
        send(.privateInterface(requestID: requestIdentifier, succeeded: succeeded))
    }

    func requestPrivateInterfaceStatus(
        requestIdentifier: UUID,
        deviceIdentifier: String,
        operationGeneration: UUID
    ) async {
        do {
            guard currentDeviceIdentifier == deviceIdentifier else {
                throw SimulatorWorkerFailure.deviceNotFound(
                    "The interface-status target does not match the attached Simulator."
                )
            }
            let status = try await mutationGate.withLocks([
                .interface(deviceIdentifier: deviceIdentifier),
            ]) {
                try await interfaceSettings.status(deviceIdentifier: deviceIdentifier)
            }
            guard toolOperationIsCurrent(operationGeneration) else { return }
            send(.privateInterfaceStatus(requestID: requestIdentifier, status))
            emitAction("private_interface_status", summary: deviceIdentifier, succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error, requestID: requestIdentifier)
            emitAction(
                "private_interface_status",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func setPrivatePrivacy(
        requestIdentifier: UUID,
        deviceIdentifier: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String,
        operationGeneration: UUID
    ) async {
        var succeeded = false
        do {
            guard currentDeviceIdentifier == deviceIdentifier else {
                throw SimulatorWorkerFailure.deviceNotFound(
                    "The permission target does not match the attached Simulator."
                )
            }
            try await privacy.set(
                deviceIdentifier: deviceIdentifier,
                action: action,
                service: service,
                bundleIdentifier: bundleIdentifier
            )
            guard toolOperationDidCommit(operationGeneration) else { return }
            succeeded = true
            emitAction(
                "privacy",
                summary: "\(action.rawValue):\(service.rawValue):\(bundleIdentifier)",
                succeeded: true
            )
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            report(error)
            emitAction("privacy", summary: error.localizedDescription, succeeded: false)
        }
        send(.privatePrivacy(requestID: requestIdentifier, succeeded: succeeded))
    }

    func requestPrivacy(
        requestIdentifier: UUID,
        deviceIdentifier: String,
        bundleIdentifier: String?,
        operationGeneration: UUID
    ) async {
        let snapshot = await privacy.snapshot(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard toolOperationIsCurrent(operationGeneration) else { return }
        send(.privacy(requestID: requestIdentifier, snapshot))
        emitAction("privacy_status", summary: bundleIdentifier ?? "runtime", succeeded: true)
    }
}
