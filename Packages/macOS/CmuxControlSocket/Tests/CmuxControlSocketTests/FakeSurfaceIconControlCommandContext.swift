import Foundation
@testable import CmuxControlSocket

/// Echoes parsed inputs without main-actor access so worker dispatch is observable.
@MainActor
final class FakeSurfaceIconControlCommandContext: ControlCommandContext {
    nonisolated func controlSurfaceIcon(_ inputs: ControlSurfaceIconInputs) -> ControlCallResult {
        .ok(.object([
            "operation": .string(inputs.operation == .set ? "set" : "clear"),
            "workspace_id": .string(inputs.workspaceID.uuidString),
            "surface_id": .string(inputs.surfaceID.uuidString),
            "owner_id": .string(inputs.ownerID),
            "ttl_seconds": .int(Int64(inputs.ttlSeconds)),
            "frame_count": .int(Int64(inputs.asset?.frames.count ?? 0)),
            "is_main_thread": .bool(Thread.isMainThread),
        ]))
    }

    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        fatalError("surface.icon must not use the coordinator's main-actor hop")
    }
}
