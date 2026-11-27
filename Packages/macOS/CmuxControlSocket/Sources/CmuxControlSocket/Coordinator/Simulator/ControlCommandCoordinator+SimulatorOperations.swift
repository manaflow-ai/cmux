internal import Foundation

extension ControlCommandCoordinator {
    nonisolated func simulatorOperation(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        let operation: ControlSimulatorOperation
        switch request.method {
        case "simulator.context":
            operation = .context
        case "simulator.prepare_screenshot":
            operation = .prepareScreenshot
        case "simulator.select_device":
            guard let deviceID = string(request.params, "device_id") else {
                return invalidSimulatorOperation("device_id is required")
            }
            operation = .selectDevice(deviceID)
        case "simulator.recover":
            operation = .recover
        case "simulator.gesture", "simulator.multi_touch":
            guard case let .array(rawEvents)? = request.params["events"],
                  !rawEvents.isEmpty, rawEvents.count <= 256,
                  let events = simulatorTouches(rawEvents),
                  request.method != "simulator.multi_touch"
                    || events.allSatisfy({ $0.secondX != nil && $0.edge == "none" }) else {
                return invalidSimulatorOperation("events must contain 1...256 valid normalized touch events")
            }
            operation = .gesture(events)
        case "simulator.tap":
            guard let point = simulatorTouch(request.params, phase: "began") else {
                return invalidSimulatorOperation("tap requires normalized x and y coordinates")
            }
            operation = .gesture([
                point,
                ControlSimulatorTouch(
                    phase: "ended", x: point.x, y: point.y,
                    secondX: point.secondX, secondY: point.secondY, edge: point.edge
                ),
            ])
        case "simulator.swipe":
            guard let events = simulatorSwipe(request.params) else {
                return invalidSimulatorOperation(
                    "swipe requires normalized from_x, from_y, to_x, and to_y coordinates"
                )
            }
            operation = .gesture(events)
        case "simulator.button":
            guard let button = string(request.params, "button") else {
                return invalidSimulatorOperation("button is required")
            }
            operation = .hardwareButton(simulatorButtonName(button))
        case "simulator.rotate":
            guard let orientation = actionKey(request.params, "orientation") else {
                return invalidSimulatorOperation("orientation is required")
            }
            operation = .rotate(orientation)
        case "simulator.core_animation":
            guard let diagnostic = string(request.params, "diagnostic"),
                  let enabled = simulatorBool(request.params, "enabled") else {
                return invalidSimulatorOperation("diagnostic and enabled are required")
            }
            operation = .coreAnimation(
                diagnostic: simulatorCADiagnosticName(diagnostic), enabled: enabled
            )
        case "simulator.memory_warning":
            operation = .memoryWarning
        case "simulator.event_log":
            let limit = simulatorInt(request.params, "limit") ?? 500
            guard (1...500).contains(limit) else {
                return invalidSimulatorOperation("limit must be between 1 and 500")
            }
            operation = .eventLog(limit: limit)
        case "simulator.tools":
            guard let action = simulatorToken(request.params, "action"),
                  ["show", "hide", "toggle"].contains(action) else {
                return invalidSimulatorOperation("action must be show, hide, or toggle")
            }
            operation = .tools(action)
        case "simulator.camera.configure":
            guard let camera = simulatorCameraOperation(request.params, targeted: true) else {
                return invalidSimulatorOperation("camera source or target parameters are invalid")
            }
            operation = camera
        case "simulator.camera.switch":
            guard case let .cameraConfigure(source, path, loops, deviceID, _)? =
                    simulatorCameraOperation(request.params, targeted: false),
                  source != "off", source != "disabled" else {
                return invalidSimulatorOperation("camera source parameters are invalid")
            }
            operation = .cameraSwitch(
                source: source, path: path, loops: loops, hostDeviceID: deviceID
            )
        case "simulator.camera.mirror":
            guard let mode = string(request.params, "mode") else {
                return invalidSimulatorOperation("mode is required")
            }
            operation = .cameraMirror(mode)
        case "simulator.camera.status":
            operation = .cameraStatus
        case "simulator.permissions.read":
            let bundleIdentifier = string(request.params, "bundle_id")
            guard bundleIdentifier.map(simulatorBundleIdentifier) ?? true else {
                return invalidSimulatorOperation("bundle_id is invalid")
            }
            operation = .permissionsRead(bundleIdentifier: bundleIdentifier)
        case "simulator.permissions.set":
            guard let action = simulatorToken(request.params, "action"),
                  let rawService = simulatorToken(request.params, "service"),
                  let bundleIdentifier = string(request.params, "bundle_id"),
                  simulatorBundleIdentifier(bundleIdentifier) else {
                return invalidSimulatorOperation(
                    "action, service, and a valid bundle_id are required"
                )
            }
            operation = .permissionsSet(
                action: action,
                service: simulatorPermissionService(rawService),
                bundleIdentifier: bundleIdentifier
            )
        case "simulator.ui.status":
            operation = .interfaceStatus
        case "simulator.ui.set":
            guard let rawOption = simulatorToken(request.params, "option"),
                  let value = simulatorToken(request.params, "value") else {
                return invalidSimulatorOperation("option and value are required")
            }
            operation = .interfaceSet(option: simulatorInterfaceOption(rawOption), value: value)
        case "simulator.accessibility":
            operation = .accessibility
        case "simulator.foreground":
            operation = .foregroundApplication
        default:
            return nil
        }
        return runSimulatorOperation(request.params, operation: operation, context: context)
    }

    private nonisolated func runSimulatorOperation(
        _ params: [String: JSONValue],
        operation: ControlSimulatorOperation,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let requestedTimeout = simulatorDouble(params, "operation_timeout_seconds")
        if let requestedTimeout,
           (!requestedTimeout.isFinite || !(0.1...550).contains(requestedTimeout)) {
            return invalidSimulatorOperation(
                "operation_timeout_seconds must be between 0.1 and 550"
            )
        }
        if requestedTimeout != nil, operation.commitsExternalMutation {
            return invalidSimulatorOperation(
                "operation_timeout_seconds is available only for read-only operations"
            )
        }
        guard let context else {
            return simulatorNoActiveWindow()
        }
        guard simulatorOperationAdmissionGate.acquire() else {
            return simulatorAdmissionFailure()
        }
        defer { simulatorOperationAdmissionGate.release() }
        let outcome: SimulatorOperationHopOutcome = context.controlResolveOnMain { seam in
            let resolution = seam.controlSimulatorBeginOperation(
                routing: self.routingSelectors(params), operation: operation
            )
            let surfaceRef: JSONValue? = if case let .started(surfaceID, _, _) = resolution {
                self.ref(.surface, surfaceID)
            } else { nil }
            return SimulatorOperationHopOutcome(resolution: resolution, surfaceRef: surfaceRef)
        }
        switch outcome.resolution {
        case let .started(surfaceID, timeout, receipt):
            let effectiveTimeout = requestedTimeout.map { min(timeout, $0) } ?? timeout
            guard let completion = receipt.wait(timeout: effectiveTimeout) else {
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.simulator.error.operationTimeout",
                        defaultValue: "The Simulator operation did not complete before the deadline"
                    ),
                    data: .object([
                        "surface_id": .string(surfaceID.uuidString),
                        "surface_ref": outcome.surfaceRef ?? .null,
                    ])
                )
            }
            switch completion {
            case let .success(payload):
                guard case let .object(values) = payload else { return .ok(payload) }
                return .ok(.object(values.merging([
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": outcome.surfaceRef ?? .null,
                ], uniquingKeysWith: { current, _ in current })))
            case let .failed(code, message):
                return simulatorSafeFailure(code: code, diagnostic: message)
            }
        case let .failed(failure):
            return simulatorTargetFailure(failure)
        case let .unavailable(message):
            return simulatorUnavailable(diagnostic: message)
        case let .invalid(message):
            return invalidSimulatorOperation(message)
        }
    }

    nonisolated func simulatorAdmissionFailure() -> ControlCallResult {
        .err(
            code: "busy",
            message: String(
                localized: "cli.simulator.error.tooManyOperations",
                defaultValue: "Too many Simulator operations are already running"
            ),
            data: nil
        )
    }

    private nonisolated func simulatorTouches(_ values: [JSONValue]) -> [ControlSimulatorTouch]? {
        var result: [ControlSimulatorTouch] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard case let .object(fields) = value,
                  let touch = simulatorTouch(fields) else { return nil }
            result.append(touch)
        }
        return result
    }

    private nonisolated func simulatorTouch(
        _ fields: [String: JSONValue], phase fallbackPhase: String? = nil
    ) -> ControlSimulatorTouch? {
        let phase = (
            string(fields, "phase") ?? string(fields, "type") ?? fallbackPhase
        )?.lowercased()
        guard let phase, ["begin", "began", "move", "moved", "end", "ended", "cancel", "cancelled"].contains(phase),
              let x = simulatorDouble(fields, "x") ?? simulatorDouble(fields, "x1"),
              let y = simulatorDouble(fields, "y") ?? simulatorDouble(fields, "y1"),
              simulatorCoordinate(x), simulatorCoordinate(y) else { return nil }
        let x2 = simulatorDouble(fields, "x2")
        let y2 = simulatorDouble(fields, "y2")
        guard (x2 == nil) == (y2 == nil),
              x2.map(simulatorCoordinate) ?? true,
              y2.map(simulatorCoordinate) ?? true else { return nil }
        guard let edge = simulatorTouchEdge(fields) else { return nil }
        return ControlSimulatorTouch(
            phase: phase, x: x, y: y, secondX: x2, secondY: y2, edge: edge
        )
    }

    nonisolated func simulatorCoordinate(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    nonisolated func simulatorDouble(
        _ params: [String: JSONValue], _ key: String
    ) -> Double? {
        switch params[key] {
        case let .double(value): value
        case let .int(value): Double(value)
        case let .string(value): Double(value)
        default: nil
        }
    }

    nonisolated func simulatorInt(_ params: [String: JSONValue], _ key: String) -> Int? {
        switch params[key] {
        case let .int(value): Int(exactly: value)
        case let .string(value): Int(value)
        default: nil
        }
    }

    nonisolated func simulatorBool(_ params: [String: JSONValue], _ key: String) -> Bool? {
        switch params[key] {
        case let .bool(value): value
        case let .string(value):
            switch value.lowercased() {
            case "true", "on", "1": true
            case "false", "off", "0": false
            default: nil
            }
        default: nil
        }
    }

    private nonisolated func invalidSimulatorOperation(_ message: String) -> ControlCallResult {
        simulatorInvalidParameters(diagnostic: message)
    }
}

private struct SimulatorOperationHopOutcome: Sendable {
    let resolution: ControlSimulatorOperationStartResolution
    let surfaceRef: JSONValue?
}
