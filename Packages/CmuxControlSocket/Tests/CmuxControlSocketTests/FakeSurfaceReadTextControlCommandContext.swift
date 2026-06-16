import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceReadTextControlCommandContext: ControlCommandContext {
    var readResolution: ControlSurfaceReadTextResolution = .tabManagerUnavailable
    var lastRead: (
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?,
        startIfNeeded: Bool
    )?

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        true
    }

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?,
        startIfNeeded: Bool
    ) -> ControlSurfaceReadTextResolution {
        lastRead = (surfaceID, hasSurfaceIDParam, includeScrollback, lineLimit, startIfNeeded)
        return readResolution
    }
}
