import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    func receiveFrameTransportFailure(
        _ failure: SimulatorFailure,
        for failedTransport: SimulatorFrameTransportDescriptor
    ) {
        guard frameTransport == failedTransport else { return }
        self.failure = failure
        frameTransport = nil
        display = nil
        status = .failed(failure)
        let previousRecoveryTask = outgoingRecoveryTask
        outgoingRecoveryGeneration &+= 1
        outgoingRecoveryTask = Task { [client] in
            _ = await previousRecoveryTask?.value
            await client.invalidateWorker()
        }
    }

    func acknowledgeFrameTransportAdoption(
        _ descriptor: SimulatorFrameTransportDescriptor
    ) {
        guard frameTransport == descriptor else { return }
        Task { [client] in
            await client.acknowledgeFrameTransportAdoption(descriptor)
        }
    }

    @discardableResult
    func enqueue(_ message: SimulatorWorkerInbound) -> Bool {
        switch outgoingContinuation.yield(message) {
        case .enqueued:
            return true
        case .dropped:
            handleOutgoingQueueOverflow()
            return false
        case .terminated:
            return false
        @unknown default:
            handleOutgoingQueueOverflow()
            return false
        }
    }

    private func handleOutgoingQueueOverflow() {
        guard !outgoingOverflowed else { return }
        outgoingOverflowed = true
        outgoingContinuation.finish()
        let deliveryTask = outgoingTask
        deliveryTask?.cancel()
        outgoingTask = nil
        let failure = SimulatorFailure(
            code: "simulator_outgoing_queue_overflow",
            message: String(
                localized: "simulator.failure.outgoingQueueOverflow",
                defaultValue: "Simulator input exceeded its bounded host queue; held input was released and the worker stopped."
            ),
            isRecoverable: true
        )
        self.failure = failure
        status = .workerCrashed
        frameTransport = nil
        display = nil
        stopLiveStatusWatcher()
        beginLocationRouteTeardown()
        outgoingRecoveryGeneration &+= 1
        outgoingRecoveryTask = Task { [client] in
            _ = await deliveryTask?.value
            await client.send(.releaseInputs)
            await client.invalidateWorker()
        }
    }

    func receive(_ event: SimulatorWorkerEvent) {
        switch event {
        case let .message(message):
            receive(message)
        case .workerStopped:
            resetCapabilityHydration()
            failPendingTextInputCompletions()
            frameTransport = nil
            hidCaptureMode = .none
            status = .workerCrashed
            clearWebInspectorState()
            beginLocationRouteTeardown()
            stopLiveStatusWatcher()
        }
    }

    private func receive(_ message: SimulatorWorkerOutbound) {
        switch message {
        case .ack:
            break
        case let .frameTransport(frameTransport):
            if frameIsVisible { self.frameTransport = frameTransport }
        case let .status(status):
            self.status = status
            if status == .streaming {
                failure = nil
                if !frameIsVisible { enqueue(.setFramebufferPublishing(false)) }
            }
            let sessionEnded: Bool = switch status {
            case .deviceUnavailable, .failed: true
            case .idle, .connecting, .streaming, .workerCrashed: false
            }
            if sessionEnded {
                resetCapabilityHydration()
                frameTransport = nil
                display = nil
                hidCaptureMode = .none
                capabilities = [.userInterfaceSettings]
                if chromeProfile != nil { capabilities.insert(.deviceChrome) }
                clearWebInspectorState()
                beginLocationRouteTeardown()
            }
            updateLiveStatusWatcher()
        case let .capabilities(capabilities):
            self.capabilities = capabilities
            capabilityHydrationCompleted = false
            if selectedDeviceID != nil { self.capabilities.insert(.userInterfaceSettings) }
            if chromeProfile != nil { self.capabilities.insert(.deviceChrome) }
            updateLiveStatusWatcher()
        case let .capabilitiesHydrated(capabilities):
            self.capabilities = capabilities
            capabilityHydrationCompleted = true
            if selectedDeviceID != nil { self.capabilities.insert(.userInterfaceSettings) }
            if chromeProfile != nil { self.capabilities.insert(.deviceChrome) }
            resolveCapabilityHydrationWaiters()
            updateLiveStatusWatcher()
        case let .display(display):
            self.display = display
        case let .hidCapture(mode):
            hidCaptureMode = mode
        case let .accessibility(_, snapshot):
            applyAccessibilitySnapshot(snapshot)
        case let .foregroundApplication(_, application):
            foregroundApplication = application
        case let .requestFailure(_, failure):
            self.failure = failure
            if frameTransport != nil { controlFailure = failure }
        case let .privacy(_, snapshot):
            privacySnapshot = snapshot
        case .privatePrivacy, .reactNativeReload, .accessibilityHighlight, .interactiveAction,
             .cameraTargetResolved, .cameraConfiguration, .cameraMirror,
             .applicationMutationPrepared, .privateInterface, .scrollWheelEnded:
            break
        case let .textInput(requestID, succeeded):
            textInputCompletions.removeValue(forKey: requestID)?(succeeded)
        case let .cameraStatus(_, status):
            cameraStatus = status
            cameraConfiguration = status.configuration
        case let .privateInterfaceStatus(_, status):
            interfaceStatus = status
        case let .webInspectorTargets(_, targets):
            webInspectorTargets = targets
            if case let .attached(_, targetID) = webInspectorSession,
               !targets.contains(where: { $0.id == targetID }) {
                applyWebInspectorSession(.detached)
            }
        case let .webInspectorSession(_, status):
            applyWebInspectorSession(status)
        case .webInspectorCommand:
            break
        case let .webInspectorHighlight(_, succeeded):
            if !succeeded { webInspectorIsHighlighted = false }
        case let .webInspectorMessage(chunk):
            let sessionID: UUID? = switch webInspectorSession {
            case let .attached(sessionID, _): sessionID
            case .detached: nil
            }
            switch webInspectorResponseBuffer.ingest(chunk, currentSessionID: sessionID) {
            case .pending:
                break
            case .completed:
                webInspectorResponses = webInspectorResponseBuffer.responses
                if let response = webInspectorResponses.first(where: { $0.id == chunk.messageID }) {
                    receiveCompletedWebInspectorResponse(response)
                }
            case .overflow:
                let failure = SimulatorFailure(
                    code: "web_inspector_response_overflow",
                    message: String(
                        localized: "simulator.failure.webInspectorResponseOverflow",
                        defaultValue: "The inspector response stream exceeded its bounded in-flight buffer."
                    ),
                    isRecoverable: true
                )
                controlFailure = failure
                failPendingWebInspectorResponses(code: failure.code, message: failure.message)
            }
        case let .actionLog(entry):
            actionLog.insert(entry, at: 0)
            if actionLog.count > Self.maximumActionLogCount {
                actionLog.removeLast(actionLog.count - Self.maximumActionLogCount)
            }
        case let .failure(failure):
            if failure.code == "worker_send_failed" || failure.code == "worker_crash_fuse" {
                failPendingTextInputCompletions()
                beginLocationRouteTeardown()
            }
            self.failure = failure
            if failure.code.hasPrefix("web_inspector") {
                failPendingWebInspectorResponses(code: failure.code, message: failure.message)
            }
            if failure.isRecoverable, frameTransport != nil {
                controlFailure = failure
            } else {
                status = .failed(failure)
            }
            updateLiveStatusWatcher()
        }
    }

    func clearWebInspectorState() {
        webInspectorTargets = []
        applyWebInspectorSession(.detached)
    }

    func applyWebInspectorSession(_ status: SimulatorWebInspectorSessionStatus) {
        let previousSessionID: UUID? = switch webInspectorSession {
        case let .attached(sessionID, _): sessionID
        case .detached: nil
        }
        let nextSessionID: UUID? = switch status {
        case let .attached(sessionID, _): sessionID
        case .detached: nil
        }
        guard previousSessionID != nextSessionID || status == .detached else {
            webInspectorSession = status
            return
        }
        failPendingWebInspectorResponses(
            code: "web_inspector_session_ended",
            message: String(
                localized: "simulator.failure.webInspectorSessionEnded",
                defaultValue: "The Web Inspector session ended before the response arrived."
            ),
            retireRequestIDs: false
        )
        retiredWebInspectorRequestIDs.removeAll()
        webInspectorSession = status
        if case .detached = status { webInspectorIsHighlighted = false }
        webInspectorResponseBuffer.reset()
        webInspectorResponses = []
    }
}
