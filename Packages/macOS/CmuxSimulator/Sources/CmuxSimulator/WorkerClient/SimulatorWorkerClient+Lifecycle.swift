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
    ) async {
        guard requestGeneration == generation, child != nil else { return }
        await broadcast(.message(.failure(SimulatorFailure(
            code: failure.code,
            message: failure.message,
            isRecoverable: true
        ))))
        discardWorker(intentional: true, clearReplayState: false)
        await handleUnexpectedWorkerStop(reason: failure.message)
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

    func ackDeadlineExpired(sequence: UInt64) async {
        guard pendingPingSequence == sequence else { return }
        pendingPingSequence = nil
        ackWatchdog = nil
        discardWorker(intentional: true, clearReplayState: false)
        await handleUnexpectedWorkerStop(reason: "The Simulator worker stopped acknowledging commands.")
    }

    func receive(_ data: Data, generation messageGeneration: UInt64) async {
        guard messageGeneration == generation,
              let message = try? JSONDecoder().decode(SimulatorWorkerOutbound.self, from: data) else {
            return
        }

        if case let .ack(sequence) = message {
            await acknowledge(sequence)
            return
        }
        if case let .status(status) = message {
            currentStatus = status
        }
        switch message {
        case let .display(display):
            lastDisplayOrientation = display.orientation
            currentDisplayMetadata = display
        case let .frameTransport(frameTransport):
            currentFrameTransport = frameTransport
            if simulatorFrameSharedMemoryNameIsValid(frameTransport.sharedMemoryName) {
                frameTransportSharedMemoryNames.insert(frameTransport.sharedMemoryName)
            }
        case let .capabilities(capabilities):
            currentCapabilities = capabilities
            currentCapabilitiesAreHydrated = false
        case let .capabilitiesHydrated(capabilities):
            currentCapabilities = capabilities
            currentCapabilitiesAreHydrated = true
        case .status(.deviceUnavailable):
            clearFrameTransportState()
            currentCapabilities = []
            currentCapabilitiesAreHydrated = false
            lastDisplayOrientation = nil
            currentDisplayMetadata = nil
            await failOutstandingRequests(with: SimulatorFailure(
                code: "simulator_device_unavailable",
                message: String(
                    localized: "simulator.failure.deviceUnavailableDuringRequest",
                    defaultValue: "The Simulator became unavailable before the request was delivered."
                ),
                isRecoverable: true
            ))
            cancelReplayWait()
        case let .status(.failed(failure)):
            clearFrameTransportState()
            currentCapabilities = []
            currentCapabilitiesAreHydrated = false
            lastDisplayOrientation = nil
            currentDisplayMetadata = nil
            await failOutstandingRequests(with: failure)
            cancelReplayWait()
        case .status(.streaming):
            attachmentAwaitingStreaming = false
            if replayAwaitingStreaming {
                replayAwaitingStreaming = false
                replayMessages = makeReplayMessages()
                await driveReplay()
            } else {
                await finishReplayIfReady()
            }
        case let .cameraConfiguration(requestID, succeeded, target):
            let wasReplay = replayRequestIDs.remove(requestID) != nil
            reconcileCameraConfiguration(
                requestIdentifier: requestID,
                succeeded: succeeded,
                resolvedTargetBundleIdentifier: target,
                wasReplay: wasReplay
            )
            if wasReplay { await driveReplay() }
        case let .cameraTargetResolved(requestID, bundleIdentifier):
            do {
                if !bundleIdentifier.isEmpty {
                    try await claimCameraCleanupOwnership(bundleIdentifier: bundleIdentifier)
                }
            } catch {
                let failure = cameraOwnershipFailure(error)
                await broadcast(.message(.requestFailure(
                    requestID: requestID,
                    failure
                )))
                discardWorker(intentional: true, clearReplayState: false)
                await broadcast(.workerStopped)
                return
            }
            acknowledgeCameraTargetResolution(for: message)
        case let .cameraMirror(requestID, succeeded):
            let wasReplay = replayRequestIDs.remove(requestID) != nil
            if let mode = cameraMirrorRequests.removeValue(forKey: requestID), succeeded {
                lastCameraMirrorMode = mode
            } else if wasReplay, !succeeded {
                lastCameraMirrorMode = nil
            }
            if wasReplay { await driveReplay() }
        case let .textInput(requestID, _):
            pendingTextInputUsages.removeValue(forKey: requestID)
            await flushDeferredMessageIfReady()
            await finishBlockingInputProbeIfReady()
        case let .interactiveAction(requestID, _):
            pendingInteractiveRequestIdentifiers.remove(requestID)
            await flushDeferredMessageIfReady()
            await finishBlockingInputProbeIfReady()
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
                await flushDeferredMessageIfReady()
            }
            if completedText || completedInteractive { await finishBlockingInputProbeIfReady() }
            if wasReplay { await driveReplay() }
        case let .scrollWheelEnded(eventID):
            if activeScrollIdentifier == eventID {
                activeScrollIdentifier = nil
                activePointer = nil
                pointerStateRevision = nil
            }
        default:
            break
        }
        await broadcast(.message(message), byteCount: data.count)
    }

    func acknowledge(_ sequence: UInt64) async {
        if let replayAcknowledgementSequence,
           sequence >= replayAcknowledgementSequence {
            self.replayAcknowledgementSequence = nil
            applyInputReleaseProofs(through: sequence)
            await driveReplay()
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
        await flushDeferredMessageIfReady()
        guard probeNeededAfterAcknowledgement else { return }
        probeNeededAfterAcknowledgement = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            await handleUnexpectedWorkerStop(reason: "The Simulator worker pipe closed while acknowledging commands.")
        }
    }

    func workerEnded(
        generation endedGeneration: UInt64,
        failure: SimulatorFailure? = nil
    ) async {
        guard endedGeneration == generation, let connection = child else { return }
        child = nil
        readerTask = nil
        unlinkSimulatorCameraSharedMemory(
            connection: connection,
            deviceIdentifier: simulatorAttachedDeviceIdentifier(from: lastAttachment),
            token: cameraSharedMemoryToken
        )
        clearLiveWorkerState()
        guard !isClosing else { return }
        if let failure {
            await broadcast(.message(.failure(failure)))
        }
        await handleUnexpectedWorkerStop(reason: "The isolated Simulator worker exited.")
    }

    func handleUnexpectedWorkerStop(reason: String) async {
        await broadcast(.workerStopped)
        guard !restartAttemptUsed else {
            await tripCrashFuse(reason: SimulatorFailure(
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
            await tripCrashFuse(reason: error)
        }
    }

    func tripCrashFuse(reason: Error) async {
        let cleanup = cameraCleanupSnapshot()
        crashFuseTripped = true
        discardWorker(intentional: true, clearReplayState: false)
        await enqueueCameraCleanup(cleanup)
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
        await broadcast(.message(.failure(failure)))
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
        cameraCleanupOwners.removeAll()
        lastCameraMirrorMode = nil
        clearHeldInputState()
    }

    func replaceWorkerForAttachmentIfNeeded() async {
        guard child != nil || lastAttachment != nil else { return }
        discardWorker(intentional: true, clearReplayState: true)
        // Existing correlated attach waiters must fail immediately. The new
        // attachment subscribes only after this terminal event is broadcast.
        await broadcast(.workerStopped)
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
            unlinkSimulatorCameraSharedMemory(
                connection: connection,
                deviceIdentifier: simulatorAttachedDeviceIdentifier(from: lastAttachment),
                token: cameraSharedMemoryToken
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
            currentDisplayMetadata = nil
            cameraReplayConfigurations.removeAll()
            cameraCleanupBundleIdentifiers.removeAll()
            cameraCleanupOwners.removeAll()
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
        clearFrameTransportState()
        currentCapabilities = []
        currentCapabilitiesAreHydrated = false
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
    }

    func clearFrameTransportState() {
        currentFrameTransport = nil
        for name in frameTransportSharedMemoryNames {
            simulatorUnlinkFrameSharedMemory(named: name)
        }
        frameTransportSharedMemoryNames.removeAll()
    }

    func acknowledgeCameraTargetResolution(for message: SimulatorWorkerOutbound) {
        guard case let .cameraTargetResolved(requestIdentifier, _) = message,
              let child,
              let data = try? JSONEncoder().encode(
                  SimulatorWorkerInbound.acknowledgeCameraTarget(requestID: requestIdentifier)
              ) else { return }
        try? child.send(data)
    }

    func finishBlockingInputProbeIfReady() async {
        guard pendingTextInputUsages.isEmpty,
              pendingInteractiveRequestIdentifiers.isEmpty,
              probeNeededAfterTextInput else { return }
        probeNeededAfterTextInput = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            await handleUnexpectedWorkerStop(
                reason: "The Simulator worker pipe closed after completing text input."
            )
        }
    }

    func flushDeferredMessageIfReady() async {
        guard let message = deferredMessages.first,
              !shouldDeferMessage(message),
              let child else { return }
        deferredMessages.removeFirst()
        do {
            try await prepareCameraCleanupOwnership(for: message)
        } catch {
            let failure = cameraOwnershipFailure(error)
            failDeferredDelivery(for: message, with: failure)
            await broadcast(.message(.failure(failure)))
            await flushDeferredMessageIfReady()
            return
        }
        do {
            try child.send(JSONEncoder().encode(message))
            await remember(message)
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
            await handleUnexpectedWorkerStop(
                reason: "The Simulator worker could not accept deferred input."
            )
        }
    }

    func failOutstandingRequests(with failure: SimulatorFailure) async {
        var requestIdentifiers = Set(deferredMessages.compactMap(\.requestIdentifier))
        requestIdentifiers.formUnion(pendingTextInputUsages.keys)
        requestIdentifiers.formUnion(pendingInteractiveRequestIdentifiers)
        requestIdentifiers.formUnion(cameraRequestConfigurations.keys)
        requestIdentifiers.formUnion(cameraSourceSwitchRequests.keys)
        requestIdentifiers.formUnion(cameraMirrorRequests.keys)
        requestIdentifiers.formUnion(requestSubscribers.keys)
        deferredMessages.removeAll()
        pendingTextInputUsages.removeAll()
        pendingInteractiveRequestIdentifiers.removeAll()
        cameraRequestConfigurations.removeAll()
        cameraSourceSwitchRequests.removeAll()
        cameraMirrorRequests.removeAll()
        probeNeededAfterTextInput = false
        failDeferredDeliveries(with: failure)
        for requestIdentifier in requestIdentifiers {
            await broadcast(.message(.requestFailure(requestID: requestIdentifier, failure)))
        }
    }

}
