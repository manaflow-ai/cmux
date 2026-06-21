import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing

@testable import CmuxTerminal

/// Minimal registered-surface stand-in: identity plus focus placement,
/// matching exactly what the registry reads through `TerminalSurfacing`.
private final class FakeSurface: TerminalSurfacing {
    let id: UUID
    let focusPlacement: TerminalSurfaceFocusPlacement

    init(id: UUID = UUID(), focusPlacement: TerminalSurfaceFocusPlacement = .workspace) {
        self.id = id
        self.focusPlacement = focusPlacement
    }
}

@MainActor
private final class RouteRetireRecorder: MainWindowRouteRetiring {
    private(set) var reasons: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(reason: String) {
        reasons.append(reason)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    /// Suspends until at least one retire has been recorded. Returns
    /// immediately when one already happened, so callers cannot lose the
    /// signal no matter how the retire task interleaves with this call
    /// (a lost-signal version of this hung CI for the full job timeout).
    func awaitFirstRetire() async {
        if !reasons.isEmpty { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("Terminal surface registry")
struct TerminalSurfaceRegistryTests {
    @Test func registersAndResolvesById() {
        let registry = TerminalSurfaceRegistry()
        let surface = FakeSurface()
        registry.register(surface)
        #expect(registry.surface(id: surface.id) === surface)
        #expect(registry.surface(id: UUID()) == nil)
    }

    @Test func unregisterRemovesSurfaceAndPlacement() {
        let registry = TerminalSurfaceRegistry()
        let surface = FakeSurface(focusPlacement: .rightSidebarDock)
        registry.register(surface)
        #expect(registry.isRightSidebarDockSurface(id: surface.id))

        registry.unregister(surface)
        #expect(registry.surface(id: surface.id) == nil)
        #expect(!registry.isRightSidebarDockSurface(id: surface.id))
    }

    @Test func placementSurvivesWhileAnotherSurfaceSharesTheId() {
        let registry = TerminalSurfaceRegistry()
        let sharedId = UUID()
        let first = FakeSurface(id: sharedId, focusPlacement: .rightSidebarDock)
        let second = FakeSurface(id: sharedId, focusPlacement: .rightSidebarDock)
        registry.register(first)
        registry.register(second)

        registry.unregister(first)
        // The replacement portal still owns the id, so its placement record
        // must survive the old surface's teardown (the legacy guard).
        #expect(registry.isRightSidebarDockSurface(id: sharedId))

        registry.unregister(second)
        #expect(!registry.isRightSidebarDockSurface(id: sharedId))
    }

    @Test func evictsDeallocatedSurfaces() {
        let registry = TerminalSurfaceRegistry()
        var surface: FakeSurface? = FakeSurface()
        let id = surface!.id
        registry.register(surface!)
        surface = nil
        // Weak table: a deallocated surface must stop resolving.
        #expect(registry.surface(id: id) == nil)
        #expect(registry.allSurfaces().isEmpty)
    }

    @Test func allSurfacesIsSortedByIdString() {
        let registry = TerminalSurfaceRegistry()
        let surfaces = (0..<5).map { _ in FakeSurface() }
        for surface in surfaces {
            registry.register(surface)
        }
        let ids = registry.allSurfaces().map(\.id.uuidString)
        #expect(ids == ids.sorted())
        #expect(Set(ids) == Set(surfaces.map(\.id.uuidString)))
    }

    @Test func runtimeSurfaceOwnershipFollowsOwnerIdGuard() throws {
        let registry = TerminalSurfaceRegistry()
        let pointer = try #require(ghostty_surface_t(bitPattern: 0xdead_beef))
        let owner = UUID()
        let intruder = UUID()

        #expect(registry.runtimeSurfaceOwnerId(pointer) == nil)
        registry.registerRuntimeSurface(pointer, ownerId: owner)
        #expect(registry.runtimeSurfaceOwnerId(pointer) == owner)

        // A stale owner must not be able to clear the record.
        registry.unregisterRuntimeSurface(pointer, ownerId: intruder)
        #expect(registry.runtimeSurfaceOwnerId(pointer) == owner)

        registry.unregisterRuntimeSurface(pointer, ownerId: owner)
        #expect(registry.runtimeSurfaceOwnerId(pointer) == nil)
    }

    @Test func reregisteringRuntimeSurfaceTransfersOwnership() throws {
        let registry = TerminalSurfaceRegistry()
        let pointer = try #require(ghostty_surface_t(bitPattern: 0xfeed_face))
        let first = UUID()
        let second = UUID()

        registry.registerRuntimeSurface(pointer, ownerId: first)
        registry.registerRuntimeSurface(pointer, ownerId: second)
        #expect(registry.runtimeSurfaceOwnerId(pointer) == second)

        // The pre-transfer owner can no longer clear the recycled pointer.
        registry.unregisterRuntimeSurface(pointer, ownerId: first)
        #expect(registry.runtimeSurfaceOwnerId(pointer) == second)
    }

    @Test func unregisterNotifiesRouteRetirerOnMainActor() async {
        let registry = TerminalSurfaceRegistry()
        let recorder = await RouteRetireRecorder()
        registry.attachRouteRetirer(recorder)

        let surface = FakeSurface()
        registry.register(surface)

        registry.unregister(surface)
        await recorder.awaitFirstRetire()
        let reasons = await recorder.reasons
        #expect(reasons == ["terminalSurface.unregister"])
    }

    @Test func unregisterWithoutRetirerDoesNotCrash() {
        let registry = TerminalSurfaceRegistry()
        let surface = FakeSurface()
        registry.register(surface)
        registry.unregister(surface)
        #expect(registry.surface(id: surface.id) == nil)
    }

    @Test func updateFocusPlacementFlipsRecordedPlacement() {
        let registry = TerminalSurfaceRegistry()
        let surface = FakeSurface(focusPlacement: .workspace)
        registry.register(surface)
        #expect(!registry.isRightSidebarDockSurface(id: surface.id))

        // Moving a live surface into the dock re-records its placement so the
        // dock-surface predicate (portal layering, focus cycling) sees the move
        // without recreating the surface.
        registry.updateFocusPlacement(id: surface.id, .rightSidebarDock)
        #expect(registry.isRightSidebarDockSurface(id: surface.id))

        registry.updateFocusPlacement(id: surface.id, .workspace)
        #expect(!registry.isRightSidebarDockSurface(id: surface.id))
    }

    @Test func updateFocusPlacementIgnoresUnregisteredId() {
        let registry = TerminalSurfaceRegistry()
        // A move record for an id with no live surface must not resurrect a
        // dropped placement entry.
        registry.updateFocusPlacement(id: UUID(), .rightSidebarDock)
        let strayId = UUID()
        registry.updateFocusPlacement(id: strayId, .rightSidebarDock)
        #expect(!registry.isRightSidebarDockSurface(id: strayId))
    }

    @Test func diagnosticSnapshotDropsUnregisteredSurfacesAndRuntimePointers() throws {
        let registry = TerminalSurfaceRegistry()
        let retained = FakeSurface(focusPlacement: .workspace)
        var closed: FakeSurface? = FakeSurface(focusPlacement: .rightSidebarDock)
        let retainedRuntimeSurface = try #require(ghostty_surface_t(bitPattern: 0x1111))
        let closedRuntimeSurface = try #require(ghostty_surface_t(bitPattern: 0x2222))

        registry.register(retained)
        registry.register(closed!)
        registry.registerRuntimeSurface(retainedRuntimeSurface, ownerId: retained.id)
        registry.registerRuntimeSurface(closedRuntimeSurface, ownerId: closed!.id)

        registry.unregister(closed!)
        registry.unregisterRuntimeSurface(closedRuntimeSurface, ownerId: closed!.id)
        closed = nil

        let snapshot = registry.diagnosticSnapshot()
        #expect(snapshot.registeredSurfaceCount == 1)
        #expect(snapshot.workspaceSurfaceCount == 1)
        #expect(snapshot.rightSidebarDockSurfaceCount == 0)
        #expect(snapshot.runtimeSurfaceCount == 1)
        #expect(snapshot.payload()["registered_surface_count"] as? Int == 1)
        #expect(snapshot.payload()["runtime_surface_count"] as? Int == 1)
    }
}
