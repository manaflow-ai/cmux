import CmuxSimulator
import Foundation

extension CMUXCLI {
    func simulatorAgentRequest(
        subcommand: String,
        arguments: SimulatorArguments
    ) throws -> SimulatorAgentRequest? {
        let values = arguments.positionals
        if subcommand != "permissions", arguments.optionValue != nil {
            throw simulatorArgumentsError(subcommand)
        }
        switch subcommand {
        case "select", "select-device":
            guard let value = oneSimulatorValue(arguments) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request(
                "simulator.select_device",
                ["device_id": value],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.selectDevice
                )
            )
        case "tap":
            guard !arguments.readsStandardInput, arguments.file == nil,
                  values.count == 2 || values.count == 4 else { throw simulatorArgumentsError(subcommand) }
            let point = try simulatorPoint(values[0], values[1])
            var params: [String: Any] = ["x": point.x, "y": point.y]
            if values.count == 4 {
                let second = try simulatorPoint(values[2], values[3])
                params["x2"] = second.x
                params["y2"] = second.y
            }
            return request("simulator.tap", params)
        case "gesture", "multitouch", "multi-touch":
            let source = try simulatorSourceValue(arguments, maximumBytes: 64 * 1_024)
            guard let data = source.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else {
                throw CLIError(message: String(
                    localized: "cli.simulator.error.invalidGestureJSON",
                    defaultValue: "simulator gesture requires a JSON touch object or array"
                ))
            }
            let events = decoded as? [Any] ?? [decoded]
            guard !events.isEmpty, events.count <= 256,
                  events.allSatisfy({ $0 is [String: Any] }) else {
                throw CLIError(message: String(
                    localized: "cli.simulator.error.invalidGestureJSON",
                    defaultValue: "simulator gesture requires a JSON touch object or array"
                ))
            }
            return request(subcommand == "gesture" ? "simulator.gesture" : "simulator.multi_touch",
                           ["events": events])
        case "swipe":
            guard !arguments.readsStandardInput, arguments.file == nil,
                  [4, 5, 8, 9].contains(values.count) else { throw simulatorArgumentsError(subcommand) }
            let from = try simulatorPoint(values[0], values[1])
            let to = try simulatorPoint(values[2], values[3])
            var params: [String: Any] = [
                "from_x": from.x, "from_y": from.y,
                "to_x": to.x, "to_y": to.y,
            ]
            if values.count >= 8 {
                let secondFrom = try simulatorPoint(values[4], values[5])
                let secondTo = try simulatorPoint(values[6], values[7])
                params["from_x2"] = secondFrom.x
                params["from_y2"] = secondFrom.y
                params["to_x2"] = secondTo.x
                params["to_y2"] = secondTo.y
            }
            if values.count == 5 || values.count == 9 {
                let stepIndex = values.count == 5 ? 4 : 8
                guard let steps = Int(values[stepIndex]), (2...64).contains(steps) else {
                    throw simulatorArgumentsError(subcommand)
                }
                params["steps"] = steps
            }
            return request("simulator.swipe", params)
        case "button":
            guard let value = oneSimulatorValue(arguments) else { throw simulatorArgumentsError(subcommand) }
            return request("simulator.button", ["button": simulatorButtonName(value)])
        case "rotate":
            guard let value = oneSimulatorValue(arguments) else { throw simulatorArgumentsError(subcommand) }
            return request("simulator.rotate", ["orientation": value.replacingOccurrences(of: "-", with: "_")])
        case "ca":
            guard !arguments.readsStandardInput, arguments.file == nil, values.count == 2,
                  let enabled = simulatorOnOff(values[1]) else { throw simulatorArgumentsError(subcommand) }
            return request("simulator.core_animation", [
                "diagnostic": simulatorCADiagnosticName(values[0]), "enabled": enabled,
            ])
        case "memory-warning", "memory_warning":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request("simulator.memory_warning", [:])
        case "event-log", "events":
            guard !arguments.readsStandardInput, arguments.file == nil, values.count <= 1 else {
                throw simulatorArgumentsError(subcommand)
            }
            var params: [String: Any] = [:]
            if let raw = values.first {
                guard let limit = Int(raw), (1...500).contains(limit) else {
                    throw simulatorArgumentsError(subcommand)
                }
                params["limit"] = limit
            }
            return request("simulator.event_log", params, output: .eventLog)
        case "tools":
            guard let action = oneSimulatorValue(arguments)?.lowercased(),
                  ["show", "hide", "toggle"].contains(action) else {
                throw simulatorArgumentsError(subcommand)
            }
            return request("simulator.tools", ["action": action])
        case "camera":
            return try simulatorCameraRequest(arguments)
        case "permissions":
            return try simulatorPermissionsRequest(arguments)
        case "ui":
            return try simulatorInterfaceRequest(arguments)
        case "accessibility", "ax":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request(
                "simulator.accessibility",
                [:],
                output: .accessibility
            )
        case "foreground":
            try requireNoSimulatorSource(arguments, subcommand: subcommand)
            return request(
                "simulator.foreground",
                [:],
                timeout: simulatorOperationDeadlines.clientTimeout(
                    for: simulatorOperationDeadlines.inspectionRead
                ),
                output: .foregroundApplication
            )
        default:
            return nil
        }
    }

    func simulatorCameraRequest(_ arguments: SimulatorArguments) throws -> SimulatorAgentRequest {
        guard !arguments.readsStandardInput, arguments.file == nil,
              let action = arguments.positionals.first?.lowercased() else {
            throw simulatorArgumentsError("camera")
        }
        let values = Array(arguments.positionals.dropFirst())
        switch action {
        case "configure":
            guard !values.isEmpty else { throw simulatorArgumentsError("camera configure") }
            let source = values.count >= 2 ? values[1] : "placeholder"
            let sourceArguments = values.count >= 2 ? Array(values.dropFirst(2)) : []
            var params = try simulatorCameraSourceParams(sourceArguments, source: source)
            params["bundle_id"] = values[0]
            return request(
                "simulator.camera.configure",
                params,
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        case "switch":
            guard let source = values.first,
                  !["off", "disabled"].contains(source.lowercased()) else {
                throw simulatorArgumentsError("camera switch")
            }
            return request(
                "simulator.camera.switch",
                try simulatorCameraSourceParams(Array(values.dropFirst()), source: source),
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        case "mirror":
            guard values.count == 1, ["auto", "on", "off"].contains(values[0]) else {
                throw simulatorArgumentsError("camera mirror")
            }
            return request("simulator.camera.mirror", ["mode": values[0]], output: .cameraStatus)
        case "status", "webcams":
            guard values.isEmpty else { throw simulatorArgumentsError("camera \(action)") }
            return request("simulator.camera.status", [:], output: .cameraStatus)
        case "stop":
            guard values.isEmpty else { throw simulatorArgumentsError("camera stop") }
            return request(
                "simulator.camera.configure",
                ["source": "off"],
                timeout: simulatorOperationDeadlines.clientTimeout(for: 160),
                output: .cameraStatus
            )
        default:
            throw simulatorArgumentsError("camera")
        }
    }

    func simulatorCameraSourceParams(
        _ arguments: [String], source rawSource: String
    ) throws -> [String: Any] {
        let source = rawSource.lowercased()
        guard ["off", "placeholder", "image", "file", "video", "host", "webcam"].contains(source) else {
            throw simulatorArgumentsError("camera")
        }
        var values = arguments
        var params: [String: Any] = ["source": source]
        if ["image", "file", "video"].contains(source) {
            guard !values.isEmpty else { throw simulatorArgumentsError("camera") }
            let rawPath = values.removeFirst()
            params["path"] = URL(
                fileURLWithPath: rawPath,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL.path
            if ["file", "video"].contains(source) { params["loops"] = true }
        } else if ["host", "webcam"].contains(source), !values.isEmpty {
            params["device_id"] = values.removeFirst()
        }
        if values.first?.lowercased() == "loop" {
            params["loops"] = true
            values.removeFirst()
        }
        guard values.isEmpty else { throw simulatorArgumentsError("camera") }
        return params
    }

    func request(
        _ method: String,
        _ params: [String: Any],
        timeout: TimeInterval? = simulatorOperationDeadlines.clientTimeout(for: 35),
        output: SimulatorAgentOutput = .completed
    ) -> SimulatorAgentRequest {
        SimulatorAgentRequest(method: method, params: params, timeout: timeout, output: output)
    }
}
