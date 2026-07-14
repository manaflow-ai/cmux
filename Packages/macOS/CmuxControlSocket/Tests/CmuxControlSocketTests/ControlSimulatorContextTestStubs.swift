import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the simulator domain seam, so a test fake
// that conforms to the full `ControlCommandContext` umbrella only has to
// implement the domain it actually exercises (the per-domain companion to the
// shared `ControlCommandContextTestStubs.swift`).

extension ControlSimulatorContext {
    func controlSimulatorOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        deviceQuery: String,
        requestedFocus: Bool
    ) -> ControlSimulatorOpenResolution { .tabManagerUnavailable }

    func controlSimulatorClose(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> ControlSimulatorCloseResolution { .tabManagerUnavailable }
}
