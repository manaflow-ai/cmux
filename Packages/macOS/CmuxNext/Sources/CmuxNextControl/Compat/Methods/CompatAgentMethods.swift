import CmuxNextDaemon
import Foundation

/// Agent-hook routing methods. Hooks ask where to deliver an event;
/// cmux-next answers from the surface the hook names. PID-based routing
/// needs process tracking the daemon owns (`list-agents`), not yet mapped.
enum CompatAgentMethods {
    static let table: [String: CompatHandler] = [
        "agent.resolve_delivery_target": .async(resolveDeliveryTarget),
    ]

    static func resolveDeliveryTarget(_ call: CompatCall) async throws -> JSON {
        guard call.string("surface_id") != nil else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.noDeliveryTarget", "No live delivery target"),
                               data: ["reason": "cmux-next resolves delivery targets by surface_id only"])
        }
        let world = try await call.world()
        guard let surface = try? call.target(world).surface() else {
            throw ControlError(code: "not_found", message: ControlStrings.text("control.error.noDeliveryTarget", "No live delivery target"))
        }
        let workspace = world.workspace(surface.workspaceUUID)
        return ["source": "surface", "workspace_id": workspace.map { .string($0.uuid) } ?? .null,
                "surface_id": .string(surface.uuid)]
    }
}
