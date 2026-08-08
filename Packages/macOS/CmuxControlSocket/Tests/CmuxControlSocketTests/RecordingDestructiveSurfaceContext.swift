import Foundation
@testable import CmuxControlSocket

/// Records the destructive surface seam calls so a test can assert that an
/// unresolvable target never reaches them (issue #9410).
@MainActor
final class RecordingDestructiveSurfaceContext: ControlCommandContext {
    var closeCalls: [UUID?] = []
    var respawnCalls: [UUID?] = []
    var closeResolution: ControlSurfaceCloseResolution = .tabManagerUnavailable

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }

    func controlSurfaceClose(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceCloseResolution {
        closeCalls.append(surfaceID)
        return closeResolution
    }

    func controlSurfaceRespawn(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceRespawnInputs
    ) -> ControlSurfaceRespawnResolution {
        respawnCalls.append(inputs.requestedSurfaceID)
        return .tabManagerUnavailable
    }
}
