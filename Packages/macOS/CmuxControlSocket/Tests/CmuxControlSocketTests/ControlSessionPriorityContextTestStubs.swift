import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the session-priority domain seam, so a
// test fake that conforms to the full `ControlCommandContext` umbrella only
// has to implement the domain it actually exercises.

extension ControlSessionPriorityContext {
    func controlSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityResolution { .tabManagerUnavailable }

    func controlSetSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        difficultyRaw: String?,
        clearDifficulty: Bool,
        manual: Bool?,
        source: String
    ) -> ControlSessionPriorityResolution { .tabManagerUnavailable }

    func controlProbeSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityProbe? { nil }

    func controlSessionPriorityStatus(
        routing: ControlRoutingSelectors
    ) -> ControlSessionPriorityStatusResolution { .tabManagerUnavailable }
}
