import Foundation

extension SimulatorWorkerClient {
    func ensureRunning() throws -> SimulatorWorkerConnection {
        try requireOpen()
        if let child { return child }
        generation &+= 1
        let launchedGeneration = generation
        let connection = try launcher.launch(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        child = connection
        isClosing = false

        let messages = connection.messages
        readerTask = Task { [weak self] in
            for await data in messages {
                guard !Task.isCancelled, let self else { return }
                await self.receive(data, generation: launchedGeneration)
            }
            guard let self else { return }
            await self.workerEnded(
                generation: launchedGeneration,
                failure: connection.terminalFailure()
            )
        }

        cameraRequestConfigurations.removeAll()
        cameraSourceSwitchRequests.removeAll()
        cameraMirrorRequests.removeAll()
        if let lastAttachment {
            replayAwaitingStreaming = true
            replayMessages.removeAll()
            replayAcknowledgementSequence = nil
            replayRequestIDs.removeAll()
            try connection.send(JSONEncoder().encode(lastAttachment))
            armReplayWatchdog(generation: launchedGeneration)
        } else {
            pendingTextInputUsages.removeAll()
        }
        return connection
    }

    func correlatedOperationDeadlineExpired(
        generation requestGeneration: UInt64,
        failure: SimulatorControlError
    ) {
        guard requestGeneration == generation, child != nil else { return }
        broadcast(.message(.failure(SimulatorFailure(
            code: failure.code,
            message: failure.message,
            isRecoverable: true
        ))))
        discardWorker(intentional: true, clearReplayState: false)
        handleUnexpectedWorkerStop(reason: failure.message)
    }

    func armResponsivenessProbe() throws {
        guard !attachmentAwaitingStreaming,
              !replayIsActive else {
            probeNeededAfterReplay = true
            return
        }
        guard pendingTextInputUsages.isEmpty,
              pendingInteractiveRequestIdentifiers.isEmpty else {
            probeNeededAfterTextInput = true
            return
        }
        guard pendingPingSequence == nil else {
            probeNeededAfterAcknowledgement = true
            return
        }
        guard let child else { return }
        let sequence = nextPingSequence
        nextPingSequence &+= 1
        try child.send(JSONEncoder().encode(SimulatorWorkerInbound.ping(sequence)))
        if !unprovenConvenienceButtonUsages.isEmpty {
            convenienceButtonProofs[sequence] = unprovenConvenienceButtonUsages
            unprovenConvenienceButtonUsages.removeAll()
        }
        captureInputReleaseProof(sequence: sequence)
        pendingPingSequence = sequence
        ackWatchdog?.cancel()
        let sleeper = self.sleeper
        let timeout = ackTimeout
        ackWatchdog = Task { [weak self] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.ackDeadlineExpired(sequence: sequence)
        }
    }

    func ackDeadlineExpired(sequence: UInt64) {
        guard pendingPingSequence == sequence else { return }
        pendingPingSequence = nil
        ackWatchdog = nil
        discardWorker(intentional: true, clearReplayState: false)
        handleUnexpectedWorkerStop(reason: "The Simulator worker stopped acknowledging commands.")
    }

    func receive(_ data: Data, generation messageGeneration: UInt64) {
        guard messageGeneration == generation,
              let message = try? JSONDecoder().decode(SimulatorWorkerOutbound.self, from: data) else {
            return
        }

        if case let .ack(sequence) = message {
            acknowledge(sequence)
            return
        }
        if case let .status(status) = message {
            currentStatus = status
        }
        switch message {
        case let .display(display):
            lastDisplayOrientation = display.orientation
        case let .context(contextID):
            currentContextID = contextID
            publishContextCache(contextID)
        case let .capabilities(capabilities):
            currentCapabilities = capabilities
        case .status(.deviceUnavailable):
            currentContextID = nil
            currentCapabilities = []
            lastDisplayOrientation = nil
            publishContextCache(nil)
            failOutstandingRequests(with: SimulatorFailure(
                code: "simulator_device_unavailable",
                message: String(
                    localized: "simulator.failure.deviceUnavailableDuringRequest",
                    defaultValue: "The Simulator became unavailable before the request was delivered."
                ),
                isRecoverable: true
            ))
            cancelReplayWait()
        case let .status(.failed(failure)):
            currentContextID = nil
            currentCapabilities = []
            lastDisplayOrientation = nil
            publishContextCache(nil)
            failOutstandingRequests(with: failure)
            cancelReplayWait()
        case .status(.streaming):
            attachmentAwaitingStreaming = false
            if replayAwaitingStreaming {
                replayAwaitingStreaming = false
                replayMessages = makeReplayMessages()
                driveReplay()
            } else {
                finishReplayIfReady()
            }
        case let .cameraConfiguration(requestID, succeeded, target):
            let wasReplay = replayRequestIDs.remove(requestID) != nil
            reconcileCameraConfiguration(
                requestIdentifier: requestID,
                succeeded: succeeded,
                resolvedTargetBundleIdentifier: target,
                wasReplay: wasReplay
            )
            if wasReplay { driveReplay() }
        case let .cameraTargetResolved(_, bundleIdentifier):
            if !bundleIdentifier.isEmpty {
                cameraCleanupBundleIdentifiers.insert(bundleIdentifier)
            }
            acknowledgeCameraTargetResolution(for: message)
        case let .cameraMirror(requestID, succeeded):
            let wasReplay = replayRequestIDs.remove(requestID) != nil
            if let mode = cameraMirrorRequests.removeValue(forKey: requestID), succeeded {
                lastCameraMirrorMode = mode
            } else if wasReplay, !succeeded {
                lastCameraMirrorMode = nil
            }
            if wasReplay { driveReplay() }
        case let .textInput(requestID, _):
            pendingTextInputUsages.removeValue(forKey: requestID)
            flushDeferredMessageIfReady()
            finishBlockingInputProbeIfReady()
        case let .interactiveAction(requestID, _):
            pendingInteractiveRequestIdentifiers.remove(requestID)
            flushDeferredMessageIfReady()
            finishBlockingInputProbeIfReady()
        case let .requestFailure(requestID, _):
            let completedText = pendingTextInputUsages.removeValue(forKey: requestID) != nil
            let completedInteractive = pendingInteractiveRequestIdentifiers.remove(requestID) != nil
            let wasReplay = replayRequestIDs.remove(requestID) != nil
            if let configuration = cameraRequestConfigurations.removeValue(forKey: requestID),
               wasReplay {
                forgetCameraConfiguration(configuration)
                if cameraReplayConfigurations.isEmpty { lastCameraMirrorMode = nil }
            }
            cameraSourceSwitchRequests.removeValue(forKey: requestID)
            if cameraMirrorRequests.removeValue(forKey: requestID) != nil, wasReplay {
                lastCameraMirrorMode = nil
            }
            if completedText || completedInteractive {
                flushDeferredMessageIfReady()
            }
            if completedText || completedInteractive { finishBlockingInputProbeIfReady() }
            if wasReplay { driveReplay() }
        case let .scrollWheelEnded(eventID):
            if activeScrollIdentifier == eventID {
                activeScrollIdentifier = nil
                activePointer = nil
                pointerStateRevision = nil
            }
        default:
            break
        }
        broadcast(.message(message), byteCount: data.count)
    }

    func acknowledge(_ sequence: UInt64) {
        if let replayAcknowledgementSequence,
           sequence >= replayAcknowledgementSequence {
            self.replayAcknowledgementSequence = nil
            applyInputReleaseProofs(through: sequence)
            driveReplay()
            return
        }
        guard let pendingPingSequence, sequence >= pendingPingSequence else { return }
        self.pendingPingSequence = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil
        let completedProofs = convenienceButtonProofs.keys.filter { $0 <= sequence }
        for proofSequence in completedProofs {
            convenienceButtonProofs.removeValue(forKey: proofSequence)
        }
        applyInputReleaseProofs(through: sequence)
        flushDeferredMessageIfReady()
        guard probeNeededAfterAcknowledgement else { return }
        probeNeededAfterAcknowledgement = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            handleUnexpectedWorkerStop(reason: "The Simulator worker pipe closed while acknowledging commands.")
        }
    }

    func workerEnded(
        generation endedGeneration: UInt64,
        failure: SimulatorFailure? = nil
    ) {
        guard endedGeneration == generation, let connection = child else { return }
        child = nil
        readerTask = nil
        Self.unlinkCameraSharedMemory(
            connection: connection,
            deviceIdentifier: Self.attachedDeviceIdentifier(from: lastAttachment)
        )
        clearLiveWorkerState()
        guard !isClosing else { return }
        if let failure {
            broadcast(.message(.failure(failure)))
        }
        handleUnexpectedWorkerStop(reason: "The isolated Simulator worker exited.")
    }

    func handleUnexpectedWorkerStop(reason: String) {
        broadcast(.workerStopped)
        guard !restartAttemptUsed else {
            tripCrashFuse(reason: SimulatorFailure(
                code: "worker_crash_fuse",
                message: reason,
                isRecoverable: true
            ))
            return
        }
        restartAttemptUsed = true
        do {
            _ = try ensureRunning()
        } catch {
            tripCrashFuse(reason: error)
        }
    }

    func tripCrashFuse(reason: Error) {
        let cleanup = cameraCleanupSnapshot()
        crashFuseTripped = true
        discardWorker(intentional: true, clearReplayState: false)
        enqueueCameraCleanup(cleanup)
        let failure = SimulatorFailure(
            code: "worker_crash_fuse",
            message: String.localizedStringWithFormat(
                String(
                    localized: "simulator.failure.workerCrashFuseReason",
                    defaultValue: "The isolated Simulator worker failed twice: %@"
                ),
                String(describing: reason)
            ),
            isRecoverable: true
        )
        broadcast(.message(.failure(failure)))
    }

    func prepareExplicitRecovery() {
        guard !isPermanentlyStopped else { return }
        restartAttemptUsed = false
        crashFuseTripped = false
        isClosing = false
        if child == nil {
            clearLiveWorkerState()
        }
    }

    func prepareForAttachment(deviceIdentifier: String) {
        guard case let .attach(existingIdentifier, _) = lastAttachment,
              existingIdentifier != deviceIdentifier else { return }
        cameraReplayConfigurations.removeAll()
        cameraCleanupBundleIdentifiers.removeAll()
        lastCameraMirrorMode = nil
        clearHeldInputState()
    }

    func replaceWorkerForAttachmentIfNeeded() {
        guard child != nil || lastAttachment != nil else { return }
        discardWorker(intentional: true, clearReplayState: true)
        // Existing correlated attach waiters must fail immediately. The new
        // attachment subscribes only after this terminal event is broadcast.
        broadcast(.workerStopped)
    }

    func clearHeldInputState() {
        resetHeldInputState()
    }

    func discardWorker(
        intentional: Bool,
        clearReplayState: Bool,
        graceful: Bool = false
    ) {
        gracefulTerminationTask?.cancel()
        gracefulTerminationTask = nil
        generation &+= 1
        if intentional { isClosing = true }
        let connection = child
        child = nil
        readerTask?.cancel()
        readerTask = nil
        if let connection {
            Self.unlinkCameraSharedMemory(
                connection: connection,
                deviceIdentifier: Self.attachedDeviceIdentifier(from: lastAttachment)
            )
        }
        if graceful, let connection {
            connection.closeInput()
            let sleeper = self.sleeper
            gracefulTerminationTask = Task {
                await withTaskCancellationHandler {
                    do {
                        // This bounded grace lets a worker exit after stdin EOF.
                        try await sleeper.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    connection.terminate()
                } onCancel: {
                    connection.terminate()
                }
            }
        } else {
            connection?.terminate()
        }
        clearLiveWorkerState()
        if clearReplayState {
            lastAttachment = nil
            lastGeometry = nil
            lastDisplayOrientation = nil
            cameraReplayConfigurations.removeAll()
            cameraCleanupBundleIdentifiers.removeAll()
            lastCameraMirrorMode = nil
            clearHeldInputState()
        }
        if intentional { isClosing = false }
    }

    func clearLiveWorkerState() {
        ackWatchdog?.cancel()
        ackWatchdog = nil
        pendingPingSequence = nil
        probeNeededAfterAcknowledgement = false
        cancelReplayWait()
        currentContextID = nil
        currentCapabilities = []
        currentStatus = nil
        failDeferredDeliveries(with: SimulatorFailure(
            code: "worker_stopped",
            message: String(
                localized: "simulator.failure.workerStoppedBeforeResponse",
                defaultValue: "The Simulator worker stopped before replying."
            ),
            isRecoverable: true
        ))
        deferredMessages.removeAll()
        pendingInteractiveRequestIdentifiers.removeAll()
        cameraRequestConfigurations.removeAll()
        cameraSourceSwitchRequests.removeAll()
        cameraMirrorRequests.removeAll()
        publishContextCache(nil)
    }

    func publishContextCache(_ contextID: UInt32?) {
        contextCacheRevision &+= 1
        let revision = contextCacheRevision
        Task { @MainActor [contextCache] in
            contextCache.update(contextID: contextID, revision: revision)
        }
    }

    func acknowledgeCameraTargetResolution(for message: SimulatorWorkerOutbound) {
        guard case let .cameraTargetResolved(requestIdentifier, _) = message,
              let child,
              let data = try? JSONEncoder().encode(
                  SimulatorWorkerInbound.acknowledgeCameraTarget(requestID: requestIdentifier)
              ) else { return }
        try? child.send(data)
    }

    func finishBlockingInputProbeIfReady() {
        guard pendingTextInputUsages.isEmpty,
              pendingInteractiveRequestIdentifiers.isEmpty,
              probeNeededAfterTextInput else { return }
        probeNeededAfterTextInput = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            handleUnexpectedWorkerStop(
                reason: "The Simulator worker pipe closed after completing text input."
            )
        }
    }

    func flushDeferredMessageIfReady() {
        guard let message = deferredMessages.first,
              !shouldDeferMessage(message),
              let child else { return }
        deferredMessages.removeFirst()
        do {
            try child.send(JSONEncoder().encode(message))
            remember(message)
            try armResponsivenessProbe()
            completeDeferredDelivery(for: message)
        } catch {
            failDeferredDelivery(
                for: message,
                with: SimulatorFailure(
                    code: "worker_unavailable",
                    message: String.localizedStringWithFormat(
                        String(
                            localized: "simulator.failure.workerCommandRejected",
                            defaultValue: "The isolated Simulator worker could not accept a command: %@"
                        ),
                        String(describing: error)
                    ),
                    isRecoverable: true
                )
            )
            discardWorker(intentional: true, clearReplayState: false)
            handleUnexpectedWorkerStop(
                reason: "The Simulator worker could not accept deferred input."
            )
        }
    }

    func failOutstandingRequests(with failure: SimulatorFailure) {
        var requestIdentifiers = Set(deferredMessages.compactMap(\.requestIdentifier))
        requestIdentifiers.formUnion(pendingTextInputUsages.keys)
        requestIdentifiers.formUnion(pendingInteractiveRequestIdentifiers)
        requestIdentifiers.formUnion(cameraRequestConfigurations.keys)
        requestIdentifiers.formUnion(cameraSourceSwitchRequests.keys)
        requestIdentifiers.formUnion(cameraMirrorRequests.keys)
        deferredMessages.removeAll()
        pendingTextInputUsages.removeAll()
        pendingInteractiveRequestIdentifiers.removeAll()
        cameraRequestConfigurations.removeAll()
        cameraSourceSwitchRequests.removeAll()
        cameraMirrorRequests.removeAll()
        probeNeededAfterTextInput = false
        failDeferredDeliveries(with: failure)
        for requestIdentifier in requestIdentifiers {
            broadcast(.message(.requestFailure(requestID: requestIdentifier, failure)))
        }
    }

}
