import Foundation
import GhosttyKit
import CmuxTerminalCore
@testable import CmuxTerminal

final class FakeSurfaceRegistry: @unchecked Sendable, TerminalSurfaceRegistering {
    private let backing = TerminalSurfaceRegistry()

    var topologyGeneration: UInt64 { backing.topologyGeneration }
    func register(
        _ surface: any TerminalSurfacing,
        terminalLifecycleID: UUID
    ) {
        backing.register(
            surface,
            terminalLifecycleID: terminalLifecycleID
        )
    }
    func advanceTerminalLifecycle(
        for surface: any TerminalSurfacing
    ) -> UUID {
        backing.advanceTerminalLifecycle(for: surface)
    }
    func unregister(_ surface: any TerminalSurfacing) {
        backing.unregister(surface)
    }
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        backing.registerRuntimeSurface(surface, ownerId: ownerId)
    }
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        backing.unregisterRuntimeSurface(surface, ownerId: ownerId)
    }
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        backing.runtimeSurfaceOwnerId(surface)
    }
    func surface(id: UUID) -> (any TerminalSurfacing)? {
        backing.surface(id: id)
    }
    func terminalLifecycleID(surfaceID: UUID) -> UUID? {
        backing.terminalLifecycleID(surfaceID: surfaceID)
    }
    func surface(
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        backing.surface(terminalLifecycleID: terminalLifecycleID)
    }
    func surface(
        id: UUID,
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        backing.surface(
            id: id,
            terminalLifecycleID: terminalLifecycleID
        )
    }
    func isCurrentSurface(
        id: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool {
        backing.isCurrentSurface(
            id: id,
            terminalLifecycleID: terminalLifecycleID
        )
    }
    func isRightSidebarDockSurface(id: UUID) -> Bool {
        backing.isRightSidebarDockSurface(id: id)
    }
    func updateFocusPlacement(
        id: UUID,
        _ placement: TerminalSurfaceFocusPlacement
    ) {
        backing.updateFocusPlacement(id: id, placement)
    }
    func allSurfaces() -> [any TerminalSurfacing] {
        backing.allSurfaces()
    }
}
