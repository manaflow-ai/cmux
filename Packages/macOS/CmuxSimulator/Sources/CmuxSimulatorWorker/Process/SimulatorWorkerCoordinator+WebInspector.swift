import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func requestWebInspectorTargets(
        requestIdentifier: UUID,
        deviceIdentifier: String,
        operationGeneration: UUID
    ) async {
        do {
            guard currentDeviceIdentifier == deviceIdentifier else {
                throw SimulatorWebInspectorError.unavailable(
                    "The Web Inspector target does not match the attached Simulator."
                )
            }
            let targets = try await webInspector.refreshTargets(
                deviceIdentifier: deviceIdentifier
            )
            guard toolOperationIsCurrent(operationGeneration) else { return }
            send(.webInspectorTargets(requestID: requestIdentifier, targets))
            emitAction(
                "web_inspector_targets",
                summary: "targets:\(targets.count)",
                succeeded: true
            )
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            reportWebInspector(error)
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "web_inspector_failed",
                    message: error.localizedDescription,
                    isRecoverable: true
                )
            ))
            emitAction(
                "web_inspector_targets",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func attachWebInspector(
        requestIdentifier: UUID,
        targetIdentifier: String,
        operationGeneration: UUID
    ) async {
        do {
            let status = try await webInspector.attach(targetIdentifier: targetIdentifier)
            guard toolOperationDidCommit(operationGeneration) else { return }
            send(.webInspectorSession(requestID: requestIdentifier, status))
            emitAction("web_inspector_attach", summary: targetIdentifier, succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            reportWebInspector(error)
            send(.webInspectorSession(requestID: requestIdentifier, .detached))
            emitAction(
                "web_inspector_attach",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func releaseWebInspector(
        requestIdentifier: UUID,
        operationGeneration: UUID
    ) async {
        do {
            try await webInspector.releaseSession()
            guard toolOperationDidCommit(operationGeneration) else { return }
            send(.webInspectorSession(requestID: requestIdentifier, .detached))
            emitAction("web_inspector_release", summary: "detached", succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            reportWebInspector(error)
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "web_inspector_release_failed",
                    message: error.localizedDescription,
                    isRecoverable: true
                )
            ))
            emitAction(
                "web_inspector_release",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func setWebInspectorHighlight(
        requestIdentifier: UUID,
        enabled: Bool,
        operationGeneration: UUID
    ) async {
        do {
            try await webInspector.setHighlight(enabled: enabled)
            guard toolOperationDidCommit(operationGeneration) else { return }
            send(.webInspectorHighlight(requestID: requestIdentifier, succeeded: true))
            emitAction(
                "web_inspector_highlight",
                summary: enabled ? "show" : "hide",
                succeeded: true
            )
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            reportWebInspector(error)
            send(.webInspectorHighlight(requestID: requestIdentifier, succeeded: false))
            emitAction(
                "web_inspector_highlight",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func sendWebInspectorMessage(
        requestIdentifier: UUID,
        json: String,
        operationGeneration: UUID
    ) async {
        do {
            try await webInspector.sendMessage(json)
            guard toolOperationDidCommit(operationGeneration) else { return }
            send(.webInspectorCommand(requestID: requestIdentifier, accepted: true))
            emitAction("web_inspector_command", summary: "json", succeeded: true)
        } catch {
            guard toolOperationIsCurrent(operationGeneration) else { return }
            reportWebInspector(error)
            send(.webInspectorCommand(requestID: requestIdentifier, accepted: false))
            emitAction(
                "web_inspector_command",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func receiveWebInspectorEvent(_ event: SimulatorWebInspectorService.Event) {
        switch event {
        case let .targets(targets):
            send(.webInspectorTargets(requestID: nil, targets))
        case let .session(status):
            send(.webInspectorSession(requestID: nil, status))
        case let .message(chunk):
            send(.webInspectorMessage(chunk))
        case let .failure(error):
            reportWebInspector(error)
        }
    }

    private func reportWebInspector(_ error: Error) {
        send(.failure(SimulatorFailure(
            code: "web_inspector_failed",
            message: error.localizedDescription,
            isRecoverable: true
        )))
    }
}
