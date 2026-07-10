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

        if let lastAttachment {
            try connection.send(JSONEncoder().encode(lastAttachment))
            replayAwaitingStreaming = true
        }
        if let lastGeometry {
            try connection.send(JSONEncoder().encode(SimulatorWorkerInbound.resize(lastGeometry)))
        }
        if lastAttachment != nil {
            if let lastDisplayOrientation {
                try connection.send(JSONEncoder().encode(
                    SimulatorWorkerInbound.rotate(lastDisplayOrientation)
                ))
            }
            if let activePointer {
                let cancellation = SimulatorPointerEvent(
                    phase: .cancelled,
                    primary: activePointer.primary,
                    secondary: activePointer.secondary,
                    edge: activePointer.edge
                )
                try connection.send(JSONEncoder().encode(SimulatorWorkerInbound.pointer(cancellation)))
                remember(.pointer(cancellation))
            }
            let pendingTextUsages = pendingTextInputUsages.values.reduce(into: Set<UInt32>()) {
                $0.formUnion($1)
            }
            pendingTextInputUsages.removeAll()
            for usage in heldKeyUsages.union(pendingTextUsages).sorted() {
                retainPotentialKeyUsage(usage)
                let release = SimulatorWorkerInbound.key(
                    SimulatorKeyEvent(usage: usage, phase: .up)
                )
                try connection.send(JSONEncoder().encode(release))
                remember(release)
            }
            let pendingConvenienceButtons = convenienceButtonProofs.values.reduce(
                into: unprovenConvenienceButtonUsages
            ) { partial, usages in
                partial.formUnion(usages)
            }
            for button in heldButtonUsages.union(pendingConvenienceButtons).sorted(by: {
                ($0.page, $0.usage) < ($1.page, $1.usage)
            }) {
                retainPotentialHIDButton(button)
                let release = SimulatorWorkerInbound.hidButton(
                    SimulatorHIDButtonEvent(button: button, phase: .up)
                )
                try connection.send(JSONEncoder().encode(release))
                remember(release)
            }

            for configuration in cameraReplayConfigurations {
                let requestID = UUID()
                replayRequestIDs.insert(requestID)
                cameraReplayRequestConfigurations[requestID] = configuration
                try connection.send(JSONEncoder().encode(
                    SimulatorWorkerInbound.configureCamera(
                        requestID: requestID,
                        configuration: configuration
                    )
                ))
            }
            if let lastCameraMirrorMode {
                let requestID = UUID()
                replayRequestIDs.insert(requestID)
                try connection.send(JSONEncoder().encode(
                    SimulatorWorkerInbound.setCameraMirror(
                        requestID: requestID,
                        mode: lastCameraMirrorMode
                    )
                ))
            }
        }
        armReplayWatchdogIfNeeded(generation: launchedGeneration)
        return connection
    }

    func armReplayWatchdogIfNeeded(generation replayGeneration: UInt64) {
        guard replayWatchdog == nil,
              replayAwaitingStreaming || !replayRequestIDs.isEmpty else { return }
        let sleeper = self.sleeper
        let timeout = replayTimeout
        replayWatchdog = Task { [weak self] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.replayDeadlineExpired(generation: replayGeneration)
        }
    }

    func replayDeadlineExpired(generation replayGeneration: UInt64) {
        guard replayGeneration == generation,
              child != nil,
              replayAwaitingStreaming || !replayRequestIDs.isEmpty else { return }
        replayWatchdog = nil
        discardWorker(intentional: true, clearReplayState: false)
        handleUnexpectedWorkerStop(
            reason: "The Simulator worker did not restore its session before the bounded deadline."
        )
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
        guard !replayAwaitingStreaming, replayRequestIDs.isEmpty else {
            probeNeededAfterReplay = true
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
            Task { @MainActor [contextCache] in
                contextCache.contextID = contextID
            }
        case let .capabilities(capabilities):
            currentCapabilities = capabilities
        case .status(.deviceUnavailable):
            currentContextID = nil
            currentCapabilities = []
            lastDisplayOrientation = nil
            Task { @MainActor [contextCache] in
                contextCache.contextID = nil
            }
            cancelReplayWait()
        case .status(.streaming):
            replayAwaitingStreaming = false
            finishReplayIfReady()
        case let .cameraConfiguration(requestID, succeeded, _):
            if replayRequestIDs.remove(requestID) != nil,
               let configuration = cameraReplayRequestConfigurations.removeValue(
                   forKey: requestID
               ), !succeeded {
                forgetCameraConfiguration(configuration)
                if cameraReplayConfigurations.isEmpty {
                    lastCameraMirrorMode = nil
                }
            }
            finishReplayIfReady()
        case let .cameraMirror(requestID, succeeded):
            if replayRequestIDs.remove(requestID) != nil, !succeeded {
                lastCameraMirrorMode = nil
            }
            finishReplayIfReady()
        case let .textInput(requestID, _):
            pendingTextInputUsages.removeValue(forKey: requestID)
        default:
            break
        }
        broadcast(.message(message), byteCount: data.count)
    }

    func acknowledge(_ sequence: UInt64) {
        guard let pendingPingSequence, sequence >= pendingPingSequence else { return }
        self.pendingPingSequence = nil
        ackWatchdog?.cancel()
        ackWatchdog = nil
        let completedProofs = convenienceButtonProofs.keys.filter { $0 <= sequence }
        for proofSequence in completedProofs {
            convenienceButtonProofs.removeValue(forKey: proofSequence)
        }
        applyInputReleaseProofs(through: sequence)
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
            message: "The isolated Simulator worker failed twice: \(reason)",
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

    func finishReplayIfReady() {
        guard !replayAwaitingStreaming, replayRequestIDs.isEmpty else { return }
        replayWatchdog?.cancel()
        replayWatchdog = nil
        guard probeNeededAfterReplay else { return }
        probeNeededAfterReplay = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            handleUnexpectedWorkerStop(
                reason: "The Simulator worker pipe closed after restoring session state."
            )
        }
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
        Task { @MainActor [contextCache] in
            contextCache.contextID = nil
        }
    }

    func cancelReplayWait() {
        replayWatchdog?.cancel()
        replayWatchdog = nil
        replayAwaitingStreaming = false
        replayRequestIDs.removeAll()
        cameraReplayRequestConfigurations.removeAll()
        probeNeededAfterReplay = false
    }

}
