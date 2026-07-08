import Foundation
import GhosttyKit
import CmuxTerminalCore
@testable import CmuxTerminal

final class FakeSurfaceRegistry: TerminalSurfaceRegistering {
    func register(_ surface: any TerminalSurfacing) {}
    func unregister(_ surface: any TerminalSurfacing) {}
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {}
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? { nil }
    func surface(id: UUID) -> (any TerminalSurfacing)? { nil }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {}
    func allSurfaces() -> [any TerminalSurfacing] { [] }
}
