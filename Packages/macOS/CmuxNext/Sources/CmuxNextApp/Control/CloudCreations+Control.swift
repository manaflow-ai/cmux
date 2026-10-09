import CmuxNextControl
import Foundation

// `cloud.machines` `creations`: New Cloud Workspace runs in flight, from the click (cx-lu8f).
extension CloudCreations {
    var controlRows: [JSONValue] {
        all.map { creation in
            .object([
                "id": .string(creation.id.uuidString.lowercased()),
                "machine_id": creation.session.map { .string($0.machineID) } ?? .null,
                "window_id": creation.windowID.map(JSONValue.string) ?? .null,
                "stage": .string(creation.stage.name),
                "stage_detail": creation.stage.failure.map(JSONValue.string) ?? .null,
                "elapsed_ms": .number(Self.milliseconds(creation.elapsed())),
                "ready_after_ms": creation.readyAfter.map { .number(Self.milliseconds($0)) } ?? .null,
                "workspace_id": creation.workspaceID.map(JSONValue.string) ?? .null,
            ])
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        (Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded()
    }
}
