import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func requestWebInspectorTargets(
        requestIdentifier: UUID,
        deviceIdentifier: String
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
            send(.webInspectorTargets(requestID: requestIdentifier, targets))
            emitAction(
                "web_inspector_targets",
                summary: "targets:\(targets.count)",
                succeeded: true
            )
        } catch {
            reportWebInspector(error)
            send(.webInspectorTargets(requestID: requestIdentifier, []))
            emitAction(
                "web_inspector_targets",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func attachWebInspector(requestIdentifier: UUID, targetIdentifier: String) async {
        do {
            let status = try await webInspector.attach(targetIdentifier: targetIdentifier)
            send(.webInspectorSession(requestID: requestIdentifier, status))
            emitAction("web_inspector_attach", summary: targetIdentifier, succeeded: true)
        } catch {
            reportWebInspector(error)
            send(.webInspectorSession(requestID: requestIdentifier, .detached))
            emitAction(
                "web_inspector_attach",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func releaseWebInspector(requestIdentifier: UUID) {
        webInspector.releaseSession()
        send(.webInspectorSession(requestID: requestIdentifier, .detached))
        emitAction("web_inspector_release", summary: "detached", succeeded: true)
    }

    func setWebInspectorHighlight(requestIdentifier: UUID, enabled: Bool) async {
        do {
            try await webInspector.setHighlight(enabled: enabled)
            send(.webInspectorHighlight(requestID: requestIdentifier, succeeded: true))
            emitAction(
                "web_inspector_highlight",
                summary: enabled ? "show" : "hide",
                succeeded: true
            )
        } catch {
            reportWebInspector(error)
            send(.webInspectorHighlight(requestID: requestIdentifier, succeeded: false))
            emitAction(
                "web_inspector_highlight",
                summary: error.localizedDescription,
                succeeded: false
            )
        }
    }

    func sendWebInspectorMessage(requestIdentifier: UUID, json: String) {
        do {
            try webInspector.sendMessage(json)
            send(.webInspectorCommand(requestID: requestIdentifier, accepted: true))
            emitAction("web_inspector_command", summary: "json", succeeded: true)
        } catch {
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
