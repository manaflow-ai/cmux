public import CmuxTerminalCore
public import Foundation
public import GhosttyKit

/// The process-wide registry of live terminal surfaces and the runtime
/// surface pointers they own.
///
/// Replaces the legacy `static let shared` singleton: the engine owner
/// constructs one registry and injects it; the app delegate attaches itself
/// as the ``MainWindowRouteRetiring`` collaborator at composition time,
/// inverting the legacy `AppDelegate.shared` reach-up.
///
/// Isolation design: the blueprint sketched a repository actor, but the
/// surface model unregisters itself from `deinit` (nonisolated, cannot await)
/// and the runtime-pointer guards run synchronously on paths that touch the
/// native `ghostty_surface_t`. The tables therefore stay behind one lock (the
/// sanctioned shape for state shared with synchronous callers), preserving
/// the legacy call contract exactly; only the route-retire notification hops
/// to the main actor, as it always did.
public final class TerminalSurfaceRegistry: TerminalSurfaceRegistering, Sendable {
    private static let deadRegistrationSweepInterval = 64

    // Synchronous `deinit` retirement cannot await an actor hop, so the
    // registry keeps its short, non-suspending mutations behind one lock.
    private let lock = NSLock()
    // SAFETY: all mutable registry state is guarded by `lock`; callers arrive
    // on the main actor and from nonisolated `deinit` paths.
    nonisolated(unsafe) private var registrationsByObjectId: [
        ObjectIdentifier: TerminalSurfaceWeakRegistration
    ] = [:]
    nonisolated(unsafe) private var registeredObjectIdsBySurfaceId: [
        UUID: Set<ObjectIdentifier>
    ] = [:]
    nonisolated(unsafe) private var registrationsSinceDeadSweep = 0
    nonisolated(unsafe) private var nextRegistrationSequence: UInt64 = 0
    nonisolated(unsafe) private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    // SAFETY: every read and write is guarded by `lock`.
    nonisolated(unsafe) private var generation: UInt64 = 0
    nonisolated(unsafe) private weak var routeRetirer: (any MainWindowRouteRetiring)?
    nonisolated(unsafe) private var routeRetireSweepScheduled = false

    /// Creates an empty registry.
    public init() {}

    /// Monotonically increasing revision of surface registrations and removals.
    public var topologyGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Attaches the collaborator notified when a surface unregisters, so
    /// recoverable main-window routes without surfaces can be retired.
    public func attachRouteRetirer(_ routeRetirer: any MainWindowRouteRetiring) {
        lock.lock()
        self.routeRetirer = routeRetirer
        lock.unlock()
    }

    /// Registers a live surface and records its focus placement.
    public func register(_ surface: any TerminalSurfacing) {
        lock.lock()
        let objectId = ObjectIdentifier(surface)
        if let existing = registrationsByObjectId[objectId],
           existing.surface === surface {
            existing.focusPlacement = surface.focusPlacement
            lock.unlock()
            return
        }

        var removedDeadRegistration = false
        if let stale = registrationsByObjectId[objectId] {
            removeRegistrationLocked(stale)
            generation &+= 1
            removedDeadRegistration = true
        }
        removedDeadRegistration =
            pruneDeadRegistrationsLocked(for: surface.id) || removedDeadRegistration

        nextRegistrationSequence &+= 1
        let registration = TerminalSurfaceWeakRegistration(
            surface: surface,
            sequence: nextRegistrationSequence
        )
        registrationsByObjectId[objectId] = registration
        registeredObjectIdsBySurfaceId[surface.id, default: []].insert(objectId)
        generation &+= 1

        registrationsSinceDeadSweep += 1
        if registrationsSinceDeadSweep >= Self.deadRegistrationSweepInterval {
            registrationsSinceDeadSweep = 0
            removedDeadRegistration =
                pruneAllDeadRegistrationsLocked() || removedDeadRegistration
        }
        let shouldScheduleRouteRetireSweep =
            removedDeadRegistration && claimRouteRetireSweepLocked()
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id, then asks the route retirer to sweep recoverable
    /// main-window routes.
    public func unregister(_ surface: any TerminalSurfacing) {
        lock.lock()
        let objectId = ObjectIdentifier(surface)
        guard let registration = registrationsByObjectId[objectId],
              registration.surfaceId == surface.id,
              registration.surface == nil || registration.surface === surface else {
            lock.unlock()
            return
        }
        removeRegistrationLocked(registration)
        generation &+= 1
        let shouldScheduleRouteRetireSweep = claimRouteRetireSweepLocked()
        lock.unlock()

        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// Removes an exact registration and its per-surface-id membership.
    private func removeRegistrationLocked(
        _ registration: TerminalSurfaceWeakRegistration
    ) {
        registrationsByObjectId.removeValue(forKey: registration.objectId)
        registeredObjectIdsBySurfaceId[registration.surfaceId]?.remove(registration.objectId)
        if registeredObjectIdsBySurfaceId[registration.surfaceId]?.isEmpty == true {
            registeredObjectIdsBySurfaceId.removeValue(forKey: registration.surfaceId)
        }
    }

    /// Prunes dead weak registrations for one stable surface id.
    @discardableResult
    private func pruneDeadRegistrationsLocked(for surfaceId: UUID) -> Bool {
        guard let objectIds = registeredObjectIdsBySurfaceId[surfaceId] else {
            return false
        }
        var removed = false
        for objectId in objectIds {
            guard let registration = registrationsByObjectId[objectId] else {
                registeredObjectIdsBySurfaceId[surfaceId]?.remove(objectId)
                if registeredObjectIdsBySurfaceId[surfaceId]?.isEmpty == true {
                    registeredObjectIdsBySurfaceId.removeValue(forKey: surfaceId)
                }
                removed = true
                continue
            }
            guard registration.surface == nil else { continue }
            removeRegistrationLocked(registration)
            generation &+= 1
            removed = true
        }
        return removed
    }

    /// Periodically prunes dead registrations so abandoned conformers cannot
    /// grow the identity ledger without bound.
    @discardableResult
    private func pruneAllDeadRegistrationsLocked() -> Bool {
        var removed = false
        let deadRegistrations = registrationsByObjectId.values.filter {
            $0.surface == nil
        }
        for registration in deadRegistrations {
            removeRegistrationLocked(registration)
            generation &+= 1
            removed = true
        }
        return removed
    }

    /// Returns live registrations for an id after removing dead weak entries.
    private func liveRegistrationsLocked(
        for surfaceId: UUID
    ) -> (
        registrations: [TerminalSurfaceWeakRegistration],
        removedDeadRegistration: Bool
    ) {
        let removedDeadRegistration = pruneDeadRegistrationsLocked(for: surfaceId)
        guard let objectIds = registeredObjectIdsBySurfaceId[surfaceId] else {
            return ([], removedDeadRegistration)
        }
        let registrations: [TerminalSurfaceWeakRegistration] = objectIds.compactMap { objectId in
            guard let registration = registrationsByObjectId[objectId],
                  registration.surface != nil else {
                return nil
            }
            return registration
        }
        return (registrations, removedDeadRegistration)
    }

    /// Claims the coalesced main-actor cleanup task while the lock is held.
    private func claimRouteRetireSweepLocked() -> Bool {
        guard !routeRetireSweepScheduled else { return false }
        routeRetireSweepScheduled = true
        return true
    }

    /// Schedules the claimed route cleanup outside the registry lock.
    private func scheduleRouteRetireSweepIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            let routeRetirer = self?.beginScheduledRouteRetireSweep()
            routeRetirer?.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
                reason: "terminalSurface.unregister"
            )
        }
    }

    /// Consumes the scheduled bit as the main-actor sweep begins. Clearing it
    /// before the callback lets an unregister performed by that callback queue
    /// the required follow-up sweep without fanning out synchronous bulk close.
    private func beginScheduledRouteRetireSweep() -> (any MainWindowRouteRetiring)? {
        lock.lock()
        routeRetireSweepScheduled = false
        let routeRetirer = routeRetirer
        lock.unlock()
        return routeRetirer
    }

    /// Records `ownerId` as the owner of a live runtime surface pointer.
    public func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }

    /// Clears the owner record, but only while `ownerId` still owns it.
    public func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: surface)
        guard runtimeSurfaceOwners[key] == ownerId else { return }
        runtimeSurfaceOwners.removeValue(forKey: key)
    }

    /// The recorded owner of a runtime surface pointer, if any.
    public func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }

    /// The registered surface with the given id, if it is still alive.
    public func surface(id: UUID) -> (any TerminalSurfacing)? {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        let object = live.registrations
            .max(by: { $0.sequence < $1.sequence })?
            .surface
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return object
    }

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    public func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        let isRightSidebarDock = live.registrations
            .max(by: { $0.sequence < $1.sequence })?
            .focusPlacement == .rightSidebarDock
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return isRightSidebarDock
    }

    /// Re-records the focus placement for a live surface that moved between the
    /// workspace area and the right-sidebar dock. No-op when the id is not
    /// currently registered, so a stale move cannot resurrect a dropped entry.
    public func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        for registration in live.registrations {
            registration.focusPlacement = placement
        }
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// A bounded count snapshot for leak diagnostics and crash/app-hang telemetry.
    public func diagnosticSnapshot() -> TerminalSurfaceRegistryDiagnosticSnapshot {
        lock.lock()
        let removedDeadRegistration = pruneAllDeadRegistrationsLocked()
        let shouldScheduleRouteRetireSweep =
            removedDeadRegistration && claimRouteRetireSweepLocked()
        let snapshots = registrationsByObjectId.values.compactMap { registration in
            registration.surface.map { surface in
                (surface: surface, focusPlacement: registration.focusPlacement)
            }
        }
        let runtimeSurfaceCount = runtimeSurfaceOwners.count
        var workspaceSurfaceCount = 0
        var rightSidebarDockSurfaceCount = 0
        for snapshot in snapshots {
            switch snapshot.focusPlacement {
            case .workspace:
                workspaceSurfaceCount += 1
            case .rightSidebarDock:
                rightSidebarDockSurfaceCount += 1
            }
        }
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)

        return TerminalSurfaceRegistryDiagnosticSnapshot(
            registeredSurfaceCount: snapshots.count,
            workspaceSurfaceCount: workspaceSurfaceCount,
            rightSidebarDockSurfaceCount: rightSidebarDockSurfaceCount,
            runtimeSurfaceCount: runtimeSurfaceCount
        )
    }

    /// All live registered surfaces, ordered by id for stable iteration.
    public func allSurfaces() -> [any TerminalSurfacing] {
        lock.lock()
        let removedDeadRegistration = pruneAllDeadRegistrationsLocked()
        let shouldScheduleRouteRetireSweep =
            removedDeadRegistration && claimRouteRetireSweepLocked()
        let objects = registrationsByObjectId.values.compactMap(\.surface)
        lock.unlock()
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
