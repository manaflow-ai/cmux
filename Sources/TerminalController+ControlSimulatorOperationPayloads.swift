import CmuxControlSocket
import CmuxSimulator
import Foundation

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

func invalidSimulatorOperation(_ message: String) -> SimulatorFailure {
    SimulatorFailure(code: "invalid_params", message: message, isRecoverable: true)
}
