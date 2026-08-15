internal import Foundation

extension ControlCommandCoordinator {
    nonisolated func simulatorInvalidParameters(
        diagnostic: String
    ) -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "cli.simulator.error.invalidParameters",
                defaultValue: "Invalid Simulator parameters"
            ),
            data: .object(["diagnostic": .string(diagnostic)])
        )
    }

    nonisolated func simulatorNoActiveWindow() -> ControlCallResult {
        .err(
            code: "unavailable",
            message: String(
                localized: "cli.simulator.error.noActiveWindow",
                defaultValue: "No active cmux window"
            ),
            data: nil
        )
    }

    nonisolated func simulatorSafeFailure(
        code: String,
        diagnostic: String,
        data: [String: JSONValue] = [:]
    ) -> ControlCallResult {
        let message: String
        if code == "invalid_params" {
            message = String(
                localized: "cli.simulator.error.invalidParameters",
                defaultValue: "Invalid Simulator parameters"
            )
        } else if code == "worker_response_timed_out" || code == "timeout" {
            message = String(
                localized: "cli.simulator.error.workerTimeout",
                defaultValue: "The Simulator worker did not respond before the deadline"
            )
        } else if code == "worker_stopped" || code == "simulator_closed" {
            message = String(
                localized: "cli.simulator.error.workerStopped",
                defaultValue: "The Simulator worker stopped before completing the operation"
            )
        } else if code.hasPrefix("web_inspector") {
            message = String(
                localized: "cli.simulator.error.webInspectorFailed",
                defaultValue: "The Web Inspector operation failed"
            )
        } else if code.hasPrefix("camera_") {
            message = String(
                localized: "cli.simulator.error.cameraFailed",
                defaultValue: "The Simulator camera operation failed"
            )
        } else if code.contains("input") || code.contains("interactive") {
            message = String(
                localized: "cli.simulator.error.inputFailed",
                defaultValue: "Simulator input transmission failed"
            )
        } else {
            message = String(
                localized: "cli.simulator.error.operationFailed",
                defaultValue: "The Simulator operation failed"
            )
        }
        var technical = data
        if !diagnostic.isEmpty { technical["diagnostic"] = .string(diagnostic) }
        return .err(code: code, message: message, data: technical.isEmpty ? nil : .object(technical))
    }

    nonisolated func simulatorUnavailable(
        diagnostic: String,
        data: [String: JSONValue] = [:]
    ) -> ControlCallResult {
        var technical = data
        if !diagnostic.isEmpty { technical["diagnostic"] = .string(diagnostic) }
        return .err(
            code: "unavailable",
            message: String(
                localized: "cli.simulator.error.operationUnavailable",
                defaultValue: "This Simulator operation is unavailable"
            ),
            data: technical.isEmpty ? nil : .object(technical)
        )
    }
}
