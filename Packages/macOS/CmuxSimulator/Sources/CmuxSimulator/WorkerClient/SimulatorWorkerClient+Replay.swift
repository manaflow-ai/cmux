import Foundation

extension SimulatorWorkerClient {
    var replayIsActive: Bool {
        replayAwaitingStreaming
            || replayAcknowledgementSequence != nil
            || !replayRequestIDs.isEmpty
            || !replayMessages.isEmpty
    }

    func makeReplayMessages() -> [SimulatorWorkerInbound] {
        var messages: [SimulatorWorkerInbound] = []
        if let lastGeometry { messages.append(.resize(lastGeometry)) }
        if let lastDisplayOrientation { messages.append(.rotate(lastDisplayOrientation)) }
        if let activePointer {
            messages.append(.pointer(SimulatorPointerEvent(
                phase: .cancelled,
                primary: activePointer.primary,
                secondary: activePointer.secondary,
                edge: activePointer.edge
            )))
        }
        let pendingTextUsages = pendingTextInputUsages.values.reduce(into: Set<UInt32>()) {
            $0.formUnion($1)
        }
        pendingTextInputUsages.removeAll()
        for usage in heldKeyUsages.union(pendingTextUsages).sorted() {
            retainPotentialKeyUsage(usage)
            messages.append(.key(SimulatorKeyEvent(usage: usage, phase: .up)))
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
            messages.append(.hidButton(SimulatorHIDButtonEvent(button: button, phase: .up)))
        }
        messages.append(contentsOf: cameraReplayConfigurations.map {
            .configureCamera(requestID: UUID(), configuration: $0)
        })
        if let lastCameraMirrorMode {
            messages.append(.setCameraMirror(requestID: UUID(), mode: lastCameraMirrorMode))
        }
        return messages
    }

    func driveReplay() async {
        guard !replayAwaitingStreaming,
              replayAcknowledgementSequence == nil,
              replayRequestIDs.isEmpty,
              let child else { return }
        guard !replayMessages.isEmpty else {
            await finishReplayIfReady()
            return
        }
        let message = replayMessages.removeFirst()
        do {
            try await prepareCameraCleanupOwnership(for: message)
        } catch {
            let failure = cameraOwnershipFailure(error)
            await broadcast(.message(.failure(failure)))
            discardWorker(intentional: true, clearReplayState: false)
            await broadcast(.workerStopped)
            return
        }
        do {
            await remember(message)
            if let requestIdentifier = message.requestIdentifier {
                replayRequestIDs.insert(requestIdentifier)
                try child.send(JSONEncoder().encode(message))
            } else {
                let sequence = nextPingSequence
                nextPingSequence &+= 1
                captureInputReleaseProof(sequence: sequence)
                replayAcknowledgementSequence = sequence
                try child.send(JSONEncoder().encode(message))
                try child.send(JSONEncoder().encode(SimulatorWorkerInbound.ping(sequence)))
            }
            armReplayWatchdog(generation: generation)
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            await handleUnexpectedWorkerStop(
                reason: "The Simulator worker pipe closed while restoring session state."
            )
        }
    }

    func armReplayWatchdog(generation replayGeneration: UInt64) {
        guard replayIsActive else { return }
        replayWatchdog?.cancel()
        let token = UUID()
        replayDeadlineToken = token
        let sleeper = self.sleeper
        let timeout = replayTimeout
        replayWatchdog = Task { [weak self] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.replayDeadlineExpired(generation: replayGeneration, token: token)
        }
    }

    func replayDeadlineExpired(generation replayGeneration: UInt64, token: UUID) async {
        guard replayGeneration == generation,
              replayDeadlineToken == token,
              child != nil,
              replayIsActive else { return }
        replayWatchdog = nil
        replayDeadlineToken = nil
        discardWorker(intentional: true, clearReplayState: false)
        await handleUnexpectedWorkerStop(
            reason: "The Simulator worker did not restore its session before the bounded deadline."
        )
    }

    func finishReplayIfReady() async {
        guard !attachmentAwaitingStreaming,
              !replayAwaitingStreaming,
              replayAcknowledgementSequence == nil,
              replayRequestIDs.isEmpty,
              replayMessages.isEmpty else { return }
        replayWatchdog?.cancel()
        replayWatchdog = nil
        replayDeadlineToken = nil
        if !deferredMessages.isEmpty {
            probeNeededAfterReplay = false
            await flushDeferredMessageIfReady()
            return
        }
        guard probeNeededAfterReplay else { return }
        probeNeededAfterReplay = false
        do {
            try armResponsivenessProbe()
        } catch {
            discardWorker(intentional: true, clearReplayState: false)
            await handleUnexpectedWorkerStop(
                reason: "The Simulator worker pipe closed after restoring session state."
            )
        }
    }

    func cancelReplayWait() {
        replayWatchdog?.cancel()
        replayWatchdog = nil
        replayDeadlineToken = nil
        replayAwaitingStreaming = false
        attachmentAwaitingStreaming = false
        replayMessages.removeAll()
        replayAcknowledgementSequence = nil
        replayRequestIDs.removeAll()
        probeNeededAfterReplay = false
    }

    func reconcileCameraConfiguration(
        requestIdentifier: UUID,
        succeeded: Bool,
        resolvedTargetBundleIdentifier: String?,
        wasReplay: Bool
    ) {
        if let configuration = cameraRequestConfigurations.removeValue(forKey: requestIdentifier) {
            if succeeded {
                if configuration.isDisabled {
                    cameraReplayConfigurations.removeAll()
                    cameraCleanupBundleIdentifiers.removeAll()
                    cameraCleanupOwners.removeAll()
                    lastCameraMirrorMode = nil
                } else {
                    rememberCameraConfiguration(
                        configuration,
                        resolvedTargetBundleIdentifier: resolvedTargetBundleIdentifier
                    )
                }
            } else if wasReplay {
                forgetCameraConfiguration(configuration)
                if cameraReplayConfigurations.isEmpty { lastCameraMirrorMode = nil }
            }
        }
        if let configuration = cameraSourceSwitchRequests.removeValue(forKey: requestIdentifier),
           succeeded {
            cameraReplayConfigurations = simulatorCameraReplayConfigurations(
                cameraReplayConfigurations,
                switchingTo: configuration
            )
        }
    }
}
