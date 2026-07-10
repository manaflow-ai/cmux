import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
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
        contextID = nil
        display = nil
        stopLiveStatusWatcher()
        beginLocationRouteTeardown()
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
            failPendingTextInputCompletions()
            contextID = nil
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
        case let .context(contextID):
            self.contextID = contextID
        case let .status(status):
            self.status = status
            if status == .streaming { failure = nil }
            if status == .deviceUnavailable {
                contextID = nil
                display = nil
                capabilities = [.userInterfaceSettings]
                if chromeProfile != nil { capabilities.insert(.deviceChrome) }
                clearWebInspectorState()
                beginLocationRouteTeardown()
            }
            updateLiveStatusWatcher()
        case let .capabilities(capabilities):
            self.capabilities = capabilities
            if selectedDeviceID != nil { self.capabilities.insert(.userInterfaceSettings) }
            if chromeProfile != nil { self.capabilities.insert(.deviceChrome) }
            updateLiveStatusWatcher()
        case let .display(display):
            self.display = display
        case let .accessibility(_, snapshot):
            applyAccessibilitySnapshot(snapshot)
        case let .foregroundApplication(_, application):
            foregroundApplication = application
        case let .requestFailure(_, failure):
            self.failure = failure
            if contextID != nil { controlFailure = failure }
        case let .privacy(_, snapshot):
            privacySnapshot = snapshot
        case .privatePrivacy, .reactNativeReload, .accessibilityHighlight, .interactiveAction,
             .cameraConfiguration, .cameraMirror, .privateInterface:
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
                clearWebInspectorSession()
            }
        case let .webInspectorSession(_, status):
            webInspectorSession = status
            if case .detached = status { clearWebInspectorSession() }
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
                    message: "The inspector response stream exceeded its bounded in-flight buffer.",
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
            if failure.isRecoverable, contextID != nil {
                controlFailure = failure
            } else {
                status = .failed(failure)
            }
            updateLiveStatusWatcher()
        }
    }

    func clearWebInspectorState() {
        webInspectorTargets = []
        clearWebInspectorSession()
    }

    private func clearWebInspectorSession() {
        failPendingWebInspectorResponses(
            code: "web_inspector_session_ended",
            message: "The Web Inspector session ended before the response arrived."
        )
        webInspectorSession = .detached
        webInspectorIsHighlighted = false
        webInspectorResponseBuffer.reset()
        webInspectorResponses = []
    }
}
