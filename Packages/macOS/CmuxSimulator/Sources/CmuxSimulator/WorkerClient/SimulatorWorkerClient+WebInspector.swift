import Foundation

extension SimulatorWorkerClient {
    func performWebInspectorAction(
        _ action: SimulatorControlAction
    ) async throws -> SimulatorControlResult? {
        switch action {
        case let .refreshWebInspectorTargets(deviceID):
            try requireWebInspectorCapability()
            let requestID = UUID()
            let targets: [SimulatorWebInspectorTarget] = try await requestWorkerValue(
                sending: .requestWebInspectorTargets(requestID: requestID, deviceID: deviceID),
                timeout: .seconds(10),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .webInspectorTargets(responseID, targets) = message,
                      responseID == requestID else { return nil }
                return targets
            }
            return .webInspectorTargets(targets)
        case let .attachWebInspector(targetID):
            try requireWebInspectorCapability()
            let requestID = UUID()
            let status: SimulatorWebInspectorSessionStatus = try await requestWorkerValue(
                sending: .attachWebInspector(requestID: requestID, targetID: targetID),
                timeout: .seconds(10),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .webInspectorSession(responseID, status) = message,
                      responseID == requestID else { return nil }
                return status
            }
            guard case .attached = status else {
                throw SimulatorControlError(
                    code: "web_inspector_attach_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.webInspectorAttachFailed",
                        defaultValue: "The isolated worker could not attach the selected inspector target."
                    )
                )
            }
            return .webInspectorSession(status)
        case .releaseWebInspector:
            let requestID = UUID()
            let status: SimulatorWebInspectorSessionStatus = try await requestWorkerValue(
                sending: .releaseWebInspector(requestID: requestID),
                timeout: .seconds(5),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .webInspectorSession(responseID, status) = message,
                      responseID == requestID else { return nil }
                return status
            }
            return .webInspectorSession(status)
        case let .setWebInspectorHighlight(enabled):
            try requireWebInspectorCapability()
            let requestID = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .setWebInspectorHighlight(requestID: requestID, enabled: enabled),
                timeout: .seconds(10),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .webInspectorHighlight(responseID, succeeded) = message,
                      responseID == requestID else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "web_inspector_highlight_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.webInspectorHighlightFailed",
                        defaultValue: "The isolated worker could not update the page highlight."
                    )
                )
            }
            return SimulatorControlResult.none
        case let .sendWebInspectorMessage(json):
            try requireWebInspectorCapability()
            let requestID = UUID()
            let accepted: Bool = try await requestWorkerValue(
                sending: .sendWebInspectorMessage(requestID: requestID, json: json),
                timeout: .seconds(5),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .webInspectorCommand(responseID, accepted) = message,
                      responseID == requestID else { return nil }
                return accepted
            }
            guard accepted else {
                throw SimulatorControlError(
                    code: "web_inspector_command_rejected",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.webInspectorCommandRejected",
                        defaultValue: "The isolated worker rejected the raw inspector command."
                    )
                )
            }
            return SimulatorControlResult.none
        default:
            return nil
        }
    }

    private func requireWebInspectorCapability() throws {
        guard currentCapabilities.contains(.webInspector) else {
            throw SimulatorControlError(
                code: "web_inspector_unavailable",
                arguments: [],
                message: String(
                    localized: "simulator.failure.webInspectorCapability",
                    defaultValue: "The selected Simulator did not negotiate native Web Inspector access."
                )
            )
        }
    }
}
