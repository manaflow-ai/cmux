import Foundation
import GhosttyKit
import CmuxTerminalCore
@testable import CmuxTerminal

final class FakeSurfaceRegistry: @unchecked Sendable, TerminalSurfaceRegistering {
    private final class WeakSurface {
        weak var value: (any TerminalSurfacing)?

        init(_ value: any TerminalSurfacing) {
            self.value = value
        }
    }

    private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    private var surfacesByID: [UUID: WeakSurface] = [:]
    private var terminalLifecycleIDsBySurfaceID: [UUID: UUID] = [:]

    var topologyGeneration: UInt64 { 0 }
    func register(
        _ surface: any TerminalSurfacing,
        terminalLifecycleID: UUID
    ) {
        surfacesByID[surface.id] = WeakSurface(surface)
        terminalLifecycleIDsBySurfaceID[surface.id] = terminalLifecycleID
    }
    func advanceTerminalLifecycle(
        for surface: any TerminalSurfacing
    ) -> UUID {
        let terminalLifecycleID = UUID()
        if surfacesByID[surface.id]?.value === surface {
            terminalLifecycleIDsBySurfaceID[surface.id] = terminalLifecycleID
        }
        return terminalLifecycleID
    }
    func unregister(_ surface: any TerminalSurfacing) {
        guard surfacesByID[surface.id]?.value === surface else { return }
        surfacesByID.removeValue(forKey: surface.id)
        terminalLifecycleIDsBySurfaceID.removeValue(forKey: surface.id)
    }
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
    func surface(id: UUID) -> (any TerminalSurfacing)? {
        surfacesByID[id]?.value
    }
    func isCurrentSurface(
        id: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool {
        guard surfacesByID[id]?.value != nil else { return false }
        guard let terminalLifecycleID else { return true }
        return terminalLifecycleIDsBySurfaceID[id] == terminalLifecycleID
    }
    func isRightSidebarDockSurface(id: UUID) -> Bool { false }
    func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {}
    func allSurfaces() -> [any TerminalSurfacing] {
        surfacesByID.values.compactMap(\.value).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }
}
