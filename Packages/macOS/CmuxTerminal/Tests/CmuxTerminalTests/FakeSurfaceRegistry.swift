import Foundation
import GhosttyKit
import CmuxTerminalCore
@testable import CmuxTerminal

final class FakeSurfaceRegistry: @unchecked Sendable, TerminalSurfaceRegistering {
    private var runtimeSurfaceOwners: [UInt: UUID] = [:]

    var topologyGeneration: UInt64 { 0 }
    func register(_ surface: any TerminalSurfacing) {}
    func unregister(_ surface: any TerminalSurfacing) {}
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        let key = UInt(bitPattern: surface)
        if runtimeSurfaceOwners[key] == ownerId {
            runtimeSurfaceOwners.removeValue(forKey: key)
        }
    }
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }
    func surface(id: UUID) -> (any TerminalSurfacing)? { nil }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {}
    func allSurfaces() -> [any TerminalSurfacing] { [] }
}
