import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

extension TerminalController {
    func controlSimulatorBeginOperation(
        routing: ControlRoutingSelectors,
        operation: ControlSimulatorOperation
    ) -> ControlSimulatorOperationStartResolution {
        switch resolveSimulatorPanel(routing: routing) {
        case let .failure(failure):
            return .failed(failure)
        case let .panel(panel):
            let coordinator = panel.coordinator
            guard operation == .recover || coordinator.status == .streaming else {
                return .unavailable(String(
                    localized: "cli.simulator.error.notStreaming",
                    defaultValue: "The selected Simulator is not streaming"
                ))
            }
            if let capability = simulatorCapability(for: operation),
               !coordinator.supports(capability) {
                return .unavailable(String(
                    localized: "cli.simulator.error.capabilityUnavailable",
                    defaultValue: "The active Simulator worker does not support this operation"
                ))
            }
            let receipt = ControlSimulatorOperationReceipt()
            Task { @MainActor [weak coordinator] in
                guard let coordinator else {
                    receipt.complete(.failed(
                        code: "simulator_closed",
                        message: String(
                            localized: "cli.simulator.error.paneClosed",
                            defaultValue: "The Simulator pane closed before the operation started"
                        )
                    ))
                    return
                }
                await self.performSimulatorOperation(operation, coordinator: coordinator, receipt: receipt)
            }
            return .started(
                surfaceID: panel.id,
                timeoutSeconds: simulatorTimeout(for: operation),
                receipt: receipt
            )
        }
    }

    private func performSimulatorOperation(
        _ operation: ControlSimulatorOperation,
        coordinator: SimulatorPaneCoordinator,
        receipt: ControlSimulatorOperationReceipt
    ) async {
        do {
            let payload: JSONValue
            switch operation {
            case .recover:
                try await coordinator.recoverAndWait()
                payload = .object(["completed": .bool(true)])
            case let .gesture(touches):
                let geometry = coordinator.display.map(SimulatorOrientationGeometry.init(display:))
                let events = try touches.map { try controlSimulatorPointerEvent($0, geometry: geometry) }
                _ = try await coordinator.perform(.interactive(.gesture(events)))
                payload = .object(["completed": .bool(true), "event_count": .int(Int64(events.count))])
            case let .hardwareButton(raw):
                guard let button = SimulatorHardwareButton(rawValue: raw) else {
                    throw invalidSimulatorOperation(String.localizedStringWithFormat(
                        String(
                            localized: "cli.simulator.error.unknownButton",
                            defaultValue: "Unknown Simulator hardware button: %@"
                        ), raw
                    ))
                }
                _ = try await coordinator.perform(.interactive(.hardwareButton(button)))
                payload = .object(["completed": .bool(true), "button": .string(button.rawValue)])
            case let .rotate(raw):
                guard let orientation = SimulatorOrientation(rawValue: raw) else {
                    throw invalidSimulatorOperation(String.localizedStringWithFormat(
                        String(
                            localized: "cli.simulator.error.unknownOrientation",
                            defaultValue: "Unknown Simulator orientation: %@"
                        ), raw
                    ))
                }
                _ = try await coordinator.perform(.interactive(.rotate(orientation)))
                payload = .object(["completed": .bool(true), "orientation": .string(raw)])
            case let .coreAnimation(raw, enabled):
                guard let diagnostic = SimulatorCADiagnostic(rawValue: raw) else {
                    throw invalidSimulatorOperation(String.localizedStringWithFormat(
                        String(
                            localized: "cli.simulator.error.unknownCADiagnostic",
                            defaultValue: "Unknown Core Animation diagnostic: %@"
                        ), raw
                    ))
                }
                _ = try await coordinator.perform(.interactive(.coreAnimation(diagnostic, enabled: enabled)))
                payload = .object([
                    "completed": .bool(true), "diagnostic": .string(raw), "enabled": .bool(enabled),
                ])
            case .memoryWarning:
                _ = try await coordinator.perform(.interactive(.memoryWarning))
                payload = .object(["completed": .bool(true)])
            case let .eventLog(limit):
                payload = .object(["events": .array(coordinator.actionLog.prefix(limit).map(simulatorEventPayload))])
            case let .cameraConfigure(source, path, loops, deviceID, bundleID):
                let configuration = try await simulatorCameraConfiguration(
                    source: source, path: path, loops: loops,
                    hostDeviceID: deviceID, bundleIdentifier: bundleID
                )
                _ = try await coordinator.perform(.configureCamera(configuration))
                let result = try await coordinator.perform(.readCameraStatus)
                payload = try simulatorCameraResultPayload(result)
            case let .cameraSwitch(source, path, loops, deviceID):
                let configuration = try await simulatorCameraConfiguration(
                    source: source, path: path, loops: loops,
                    hostDeviceID: deviceID, bundleIdentifier: nil
                )
                _ = try await coordinator.perform(.switchCameraSource(configuration))
                let result = try await coordinator.perform(.readCameraStatus)
                payload = try simulatorCameraResultPayload(result)
            case let .cameraMirror(raw):
                guard let mode = SimulatorCameraMirrorMode(rawValue: raw) else {
                    throw invalidSimulatorOperation(String(
                        localized: "cli.simulator.error.invalidMirrorMode",
                        defaultValue: "Camera mirror mode must be auto, on, or off"
                    ))
                }
                _ = try await coordinator.perform(.setCameraMirror(mode))
                let result = try await coordinator.perform(.readCameraStatus)
                payload = try simulatorCameraResultPayload(result)
            case .cameraStatus:
                payload = try simulatorCameraResultPayload(
                    try await coordinator.perform(.readCameraStatus)
                )
            case let .permissionsRead(bundleIdentifier):
                let deviceID = try simulatorSelectedDeviceID(coordinator)
                payload = try simulatorPrivacyResultPayload(
                    try await coordinator.perform(.readPrivacy(
                        deviceID: deviceID,
                        bundleIdentifier: bundleIdentifier
                    ))
                )
            case let .permissionsSet(rawAction, rawService, bundleIdentifier):
                let deviceID = try simulatorSelectedDeviceID(coordinator)
                guard let action = SimulatorPrivacyAction(rawValue: rawAction),
                      let service = SimulatorPrivacyService(rawValue: rawService),
                      service != .all || action == .reset else {
                    throw invalidSimulatorOperation(String(
                        localized: "cli.simulator.error.invalidPermission",
                        defaultValue: "The Simulator permission action or service is invalid"
                    ))
                }
                _ = try await coordinator.perform(.setPrivacy(
                    deviceID: deviceID,
                    action: action,
                    service: service,
                    bundleIdentifier: bundleIdentifier
                ))
                payload = try simulatorPrivacyResultPayload(
                    try await coordinator.perform(.readPrivacy(
                        deviceID: deviceID,
                        bundleIdentifier: bundleIdentifier
                    )),
                    action: action,
                    service: service
                )
            case .interfaceStatus:
                let deviceID = try simulatorSelectedDeviceID(coordinator)
                payload = try simulatorInterfaceResultPayload(
                    try await coordinator.perform(.readInterfaceStatus(deviceID: deviceID))
                )
            case let .interfaceSet(option, value):
                let deviceID = try simulatorSelectedDeviceID(coordinator)
                let setting = try simulatorInterfaceSetting(option: option, value: value)
                _ = try await coordinator.perform(.setInterface(
                    deviceID: deviceID,
                    setting: setting
                ))
                payload = try simulatorInterfaceResultPayload(
                    try await coordinator.perform(.readInterfaceStatus(deviceID: deviceID)),
                    option: option
                )
            case .accessibility:
                payload = try simulatorAccessibilityResultPayload(
                    try await coordinator.perform(.readAccessibility)
                )
            case .foregroundApplication:
                payload = try simulatorForegroundApplicationResultPayload(
                    try await coordinator.perform(.readForegroundApplication)
                )
            }
            receipt.complete(.success(payload))
        } catch let failure as SimulatorFailure {
            receipt.complete(.failed(code: failure.code, message: failure.message))
        } catch {
            receipt.complete(.failed(
                code: "simulator_operation_failed",
                message: String(
                    localized: "cli.simulator.error.operationFailed",
                    defaultValue: "The Simulator operation failed"
                )
            ))
        }
    }

    private func simulatorCapability(
        for operation: ControlSimulatorOperation
    ) -> SimulatorCapability? {
        switch operation {
        case .recover: nil
        case let .gesture(events): events.contains(where: { $0.secondX != nil }) ? .multiTouch : .touch
        case .hardwareButton: .hardwareButtons
        case .rotate: .rotation
        case .coreAnimation: .coreAnimationDiagnostics
        case .memoryWarning: .memoryWarning
        case .cameraConfigure, .cameraSwitch, .cameraMirror, .cameraStatus: .cameraInjection
        case .permissionsRead: .extendedPermissions
        case let .permissionsSet(_, rawService, _):
            if let service = SimulatorPrivacyService(rawValue: rawService),
               service == .all || service.requiresIsolatedMutation {
                .extendedPermissions
            } else {
                nil
            }
        case .interfaceStatus, .interfaceSet: .userInterfaceSettings
        case .accessibility: .accessibility
        case .foregroundApplication: .foregroundApplication
        case .eventLog: nil
        }
    }

    private func simulatorTimeout(for operation: ControlSimulatorOperation) -> TimeInterval {
        if case .recover = operation { return 130 }
        if case .cameraConfigure = operation { return 160 }
        if case .cameraSwitch = operation { return 160 }
        if case .interfaceStatus = operation { return 125 }
        if case .interfaceSet = operation { return 125 }
        if case let .permissionsSet(_, service, _) = operation {
            return service == SimulatorPrivacyService.all.rawValue ? 130 : 55
        }
        if case .accessibility = operation { return 35 }
        return 35
    }

    private func simulatorSelectedDeviceID(
        _ coordinator: SimulatorPaneCoordinator
    ) throws -> String {
        guard let deviceID = coordinator.selectedDeviceID else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.deviceRequired",
                defaultValue: "The Simulator pane has no selected device"
            ))
        }
        return deviceID
    }

    private func simulatorPrivacyResultPayload(
        _ result: SimulatorControlResult,
        action: SimulatorPrivacyAction? = nil,
        service: SimulatorPrivacyService? = nil
    ) throws -> JSONValue {
        guard case let .privacy(snapshot) = result else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.permissionStatusMissing",
                defaultValue: "The Simulator worker returned no permission status"
            ))
        }
        var payload: [String: JSONValue] = [
            "bundle_id": snapshot.bundleIdentifier.map(JSONValue.string) ?? .null,
            "permissions": simulatorPrivacyAuthorizationsPayload(snapshot.authorizations),
        ]
        if snapshot.bundleIdentifier == nil {
            payload["applications"] = .array(snapshot.applications.map { application in
                .object([
                    "bundle_id": .string(application.bundleIdentifier),
                    "permissions": simulatorPrivacyAuthorizationsPayload(
                        application.authorizations
                    ),
                ])
            })
            payload["truncated"] = .bool(snapshot.isTruncated)
        }
        if let action { payload["action"] = .string(action.rawValue) }
        if let service { payload["service"] = .string(service.rawValue) }
        return .object(payload)
    }

    private func simulatorPrivacyAuthorizationsPayload(
        _ authorizations: [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    ) -> JSONValue {
        .object(authorizations.reduce(into: [:]) {
            $0[$1.key.rawValue] = .string($1.value.rawValue)
        })
    }

    private func simulatorInterfaceSetting(
        option: String,
        value: String
    ) throws -> SimulatorInterfaceSetting {
        switch option {
        case "appearance":
            guard let appearance = SimulatorInterfaceSetting.Appearance(rawValue: value) else {
                break
            }
            return .appearance(appearance)
        case "liquid-glass":
            guard let style = SimulatorInterfaceSetting.LiquidGlass(rawValue: value) else { break }
            return .liquidGlass(style)
        case "color-filter":
            guard let filter = SimulatorInterfaceSetting.ColorFilter(rawValue: value) else { break }
            return .colorFilter(filter)
        case "text-size":
            if let size = SimulatorInterfaceSetting.ContentSize(rawValue: value) {
                return .contentSize(size)
            }
            if let adjustment = SimulatorInterfaceSetting.ContentSizeAdjustment(rawValue: value) {
                return .contentSizeAdjustment(adjustment)
            }
        case "reduce-motion":
            if let enabled = simulatorInterfaceToggle(value) { return .reduceMotion(enabled) }
        case "increase-contrast":
            if let enabled = simulatorInterfaceToggle(value) { return .increaseContrast(enabled) }
        case "show-borders":
            if let enabled = simulatorInterfaceToggle(value) { return .buttonShapes(enabled) }
        case "reduce-transparency":
            if let enabled = simulatorInterfaceToggle(value) { return .reduceTransparency(enabled) }
        case "voiceover":
            if let enabled = simulatorInterfaceToggle(value) { return .voiceOver(enabled) }
        default:
            break
        }
        throw invalidSimulatorOperation(String(
            localized: "cli.simulator.error.invalidUISetting",
            defaultValue: "The Simulator interface option or value is invalid"
        ))
    }

    private func simulatorInterfaceToggle(_ value: String) -> Bool? {
        switch value {
        case "on": true
        case "off": false
        default: nil
        }
    }

    private func simulatorInterfaceResultPayload(
        _ result: SimulatorControlResult,
        option: String? = nil
    ) throws -> JSONValue {
        guard case let .interfaceStatus(status) = result else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.interfaceStatusMissing",
                defaultValue: "The Simulator worker returned no interface status"
            ))
        }
        let unsupported = JSONValue.string("unsupported")
        let settings: [String: JSONValue] = [
            "appearance": status.appearance.map { .string($0.rawValue) } ?? unsupported,
            "liquid-glass": .string(status.liquidGlass.rawValue),
            "color-filter": .string(status.colorFilter.rawValue),
            "text-size": status.contentSize.map { .string($0.rawValue) } ?? unsupported,
            "reduce-motion": .string(status.reduceMotion ? "on" : "off"),
            "increase-contrast": status.increaseContrast.map {
                .string($0 ? "on" : "off")
            } ?? unsupported,
            "show-borders": .string(status.buttonShapes ? "on" : "off"),
            "reduce-transparency": .string(status.reduceTransparency ? "on" : "off"),
            "voiceover": .string(status.voiceOver ? "on" : "off"),
        ]
        var payload: [String: JSONValue] = ["settings": .object(settings)]
        if let option {
            payload["option"] = .string(option)
            payload["value"] = settings[option] ?? unsupported
        }
        return .object(payload)
    }

}

func controlSimulatorPointerEvent(
    _ value: ControlSimulatorTouch,
    geometry: SimulatorOrientationGeometry?
) throws -> SimulatorPointerEvent {
        let phase: SimulatorTouchPhase = switch value.phase {
        case "begin", "began": .began
        case "move", "moved": .moved
        case "end", "ended": .ended
        case "cancel", "cancelled": .cancelled
        default: throw invalidSimulatorOperation(String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.unknownTouchPhase",
                defaultValue: "Unknown Simulator touch phase: %@"
            ), value.phase
        ))
        }
        let edge: SimulatorEdge = switch value.edge {
        case "none", "0": .none
        case "left", "1": .left
        case "top", "2": .top
        case "bottom", "3": .bottom
        case "right", "4": .right
        default: throw invalidSimulatorOperation(String.localizedStringWithFormat(
            String(
                localized: "cli.simulator.error.unknownTouchEdge",
                defaultValue: "Unknown Simulator touch edge: %@"
            ), value.edge
        ))
        }
        let secondary = value.secondX.flatMap { x in
            value.secondY.map { SimulatorPoint(x: x, y: $0) }
        }
        let event = SimulatorPointerEvent(
            phase: phase,
            primary: SimulatorPoint(x: value.x, y: value.y),
            secondary: secondary,
            edge: edge
        )
        return geometry?.rawPointerEvent(event) ?? event
}

func simulatorAccessibilityResultPayload(
    _ result: SimulatorControlResult
) throws -> JSONValue {
    guard case let .accessibility(snapshot) = result else {
        throw invalidSimulatorOperation(String(
            localized: "cli.simulator.error.accessibilityMissing",
            defaultValue: "The Simulator worker returned no accessibility snapshot"
        ))
    }
    return .object([
        "roots": .array(snapshot.roots.map(simulatorAccessibilityNodePayload)),
        "node_count": .int(Int64(snapshot.nodeCount)),
        "truncated": .bool(snapshot.isTruncated),
        "display": .object([
            "width": .int(Int64(snapshot.display.width)),
            "height": .int(Int64(snapshot.display.height)),
            "scale": .double(snapshot.display.scale),
            "orientation": .string(snapshot.display.orientation.rawValue),
        ]),
    ])
}

func simulatorForegroundApplicationResultPayload(
    _ result: SimulatorControlResult
) throws -> JSONValue {
    guard case let .foregroundApplication(application) = result else {
        throw invalidSimulatorOperation(String(
            localized: "cli.simulator.error.foregroundMissing",
            defaultValue: "The Simulator worker returned no foreground-app result"
        ))
    }
    guard let application else { return .object(["application": .null]) }
    return .object(["application": .object([
        "bundle_id": .string(application.bundleIdentifier),
        "pid": application.processIdentifier.map { .int(Int64($0)) } ?? .null,
        "name": application.name.map(JSONValue.string) ?? .null,
        "version": application.version.map(JSONValue.string) ?? .null,
        "build": application.build.map(JSONValue.string) ?? .null,
        "minimum_os_version": application.minimumOSVersion.map(JSONValue.string) ?? .null,
        "executable": application.executable.map(JSONValue.string) ?? .null,
        "bundle_path": application.bundlePath.map(JSONValue.string) ?? .null,
        "is_react_native": .bool(application.isReactNative),
    ])])
}

private func simulatorAccessibilityNodePayload(
    _ node: SimulatorAccessibilityNode
) -> JSONValue {
    .object([
        "AXLabel": node.label.map(JSONValue.string) ?? .null,
        "AXValue": node.value.map(JSONValue.string) ?? .null,
        "AXUniqueId": .string(node.id),
        "enabled": node.isEnabled.map(JSONValue.bool) ?? .null,
        "frame": node.frame.map { frame in
            .object([
                "x": .double(frame.x), "y": .double(frame.y),
                "width": .double(frame.width), "height": .double(frame.height),
            ])
        } ?? .null,
        "role_description": node.roleDescription.map(JSONValue.string) ?? .null,
        "type": node.role.map(JSONValue.string) ?? .null,
        "children": .array(node.children.map(simulatorAccessibilityNodePayload)),
    ])
}

private func invalidSimulatorOperation(_ message: String) -> SimulatorFailure {
    SimulatorFailure(code: "invalid_params", message: message, isRecoverable: true)
}
