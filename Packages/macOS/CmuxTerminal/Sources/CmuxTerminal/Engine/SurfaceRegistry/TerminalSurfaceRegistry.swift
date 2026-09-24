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
    private static let deadRegistrationSweepBudget = 8
    // A weak load is a temporary strong retain. Keep every loaded surface in
    // the returned snapshot until after `lock` is released so a last-reference
    // deinit can synchronously unregister without re-entering this lock.
    private typealias LiveRegistrationSnapshot = (
        registration: TerminalSurfaceWeakRegistration,
        surface: any TerminalSurfacing
    )
    private typealias DeadRegistrationSweepResult = (
        liveRegistrations: [LiveRegistrationSnapshot],
        removedDeadRegistration: Bool
    )
    private typealias LifecycleLookupResult = (
        surface: (any TerminalSurfacing)?,
        liveRegistrations: [LiveRegistrationSnapshot],
        removedDeadRegistration: Bool
    )

    // Synchronous `deinit` retirement cannot await an actor hop, so the
    // registry keeps its short, non-suspending mutations behind one lock.
    private let lock = NSLock()
    // SAFETY: all mutable registry state is guarded by `lock`; callers arrive
    // on the main actor and from nonisolated `deinit` paths.
    nonisolated(unsafe) private var registrationsByObjectId: [
        ObjectIdentifier: TerminalSurfaceWeakRegistration
    ] = [:]
    // SAFETY: every membership read and write is guarded by `lock`.
    nonisolated(unsafe) private var registeredObjectIdsBySurfaceId: [
        UUID: Set<ObjectIdentifier>
    ] = [:]
    // SAFETY: every process-generation read and write is guarded by `lock`.
    nonisolated(unsafe) private var terminalLifecycleIdByObjectId: [
        ObjectIdentifier: UUID
    ] = [:]
    // SAFETY: every process-generation index read and write is guarded by `lock`.
    nonisolated(unsafe) private var registrationByTerminalLifecycleId: [
        UUID: TerminalSurfaceWeakRegistration
    ] = [:]
    // SAFETY: every sweep-cursor read and write is guarded by `lock`.
    nonisolated(unsafe) private var nextDeadRegistrationSweepObjectId: ObjectIdentifier?
    // SAFETY: every registration-sequence read and write is guarded by `lock`.
    nonisolated(unsafe) private var nextRegistrationSequence: UInt64 = 0
    // SAFETY: every traversal-head read and write is guarded by `lock`.
    nonisolated(unsafe) private var incrementalTraversalHead:
        TerminalSurfaceWeakRegistration?
    // SAFETY: every access is guarded by `lock`.
    nonisolated(unsafe) private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    // SAFETY: every read and write is guarded by `lock`.
    nonisolated(unsafe) private var generation: UInt64 = 0
    // SAFETY: every access is guarded by `lock`.
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
    /// recoverable main-window route lifecycle can be audited.
    public func attachRouteRetirer(_ routeRetirer: any MainWindowRouteRetiring) {
        lock.lock()
        self.routeRetirer = routeRetirer
        lock.unlock()
    }

    /// Registers a live surface, its process generation, and its focus placement.
    /// - Parameters:
    ///   - surface: The surface model being registered.
    ///   - terminalLifecycleID: The generation exported to its current child.
    public func register(
        _ surface: any TerminalSurfacing,
        terminalLifecycleID: UUID
    ) {
        lock.lock()
        let objectId = ObjectIdentifier(surface)
        var existingSurface: (any TerminalSurfacing)?
        if let existing = registrationsByObjectId[objectId] {
            existingSurface = existing.surface
            if existingSurface === surface {
                // Reinsert the exact model as the newest registration so a
                // deliberate re-registration regains current ownership for a
                // stable surface id without reviving its prior generation.
                removeRegistrationLocked(existing)
            }
        }

        var removedDeadRegistration = false
        if let stale = registrationsByObjectId[objectId] {
            removeRegistrationLocked(stale)
            generation &+= 1
            removedDeadRegistration = true
        }
        nextRegistrationSequence &+= 1
        let registration = TerminalSurfaceWeakRegistration(
            surface: surface,
            sequence: nextRegistrationSequence
        )
        registrationsByObjectId[objectId] = registration
        registeredObjectIdsBySurfaceId[surface.id, default: []].insert(objectId)
        setTerminalLifecycleLocked(terminalLifecycleID, for: registration)
        insertIntoDeadRegistrationSweepLocked(registration)
        registration.nextTraversalRegistration = incrementalTraversalHead
        incrementalTraversalHead?.previousTraversalRegistration = registration
        incrementalTraversalHead = registration
        generation &+= 1

        let sweep = pruneDeadRegistrationsLocked(
            limit: Self.deadRegistrationSweepBudget
        )
        removedDeadRegistration = sweep.removedDeadRegistration || removedDeadRegistration
        let shouldScheduleRouteRetireSweep =
            removedDeadRegistration && claimRouteRetireSweepLocked()
        lock.unlock()
        withExtendedLifetime((existingSurface, sweep.liveRegistrations)) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// Atomically retires the registered surface's current process generation.
    /// - Parameter surface: The retained surface whose child is being replaced.
    /// - Returns: The generation identity for the surface's next child runtime.
    public func advanceTerminalLifecycle(
        for surface: any TerminalSurfacing
    ) -> UUID {
        let terminalLifecycleID = UUID()
        lock.lock()
        let registration = registrationsByObjectId[ObjectIdentifier(surface)]
        let registeredSurface = registration?.surface
        guard let registration,
              registration.isTraversalRegistered,
              registeredSurface === surface else {
            lock.unlock()
            withExtendedLifetime(registeredSurface) {}
            return terminalLifecycleID
        }
        setTerminalLifecycleLocked(terminalLifecycleID, for: registration)
        lock.unlock()
        withExtendedLifetime(registeredSurface) {}
        return terminalLifecycleID
    }

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id, then asks the route retirer to sweep recoverable
    /// main-window routes.
    public func unregister(_ surface: any TerminalSurfacing) {
        lock.lock()
        let objectId = ObjectIdentifier(surface)
        guard let registration = registrationsByObjectId[objectId],
              registration.surfaceId == surface.id else {
            lock.unlock()
            return
        }
        let registeredSurface = registration.surface
        guard registeredSurface == nil || registeredSurface === surface else {
            lock.unlock()
            withExtendedLifetime(registeredSurface) {}
            return
        }
        removeRegistrationLocked(registration)
        generation &+= 1
        let shouldScheduleRouteRetireSweep = claimRouteRetireSweepLocked()
        lock.unlock()
        withExtendedLifetime(registeredSurface) {}

        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// Removes an exact registration and its per-surface-id membership.
    private func removeRegistrationLocked(
        _ registration: TerminalSurfaceWeakRegistration
    ) {
        unlinkIncrementalTraversalRegistrationLocked(registration)
        removeFromDeadRegistrationSweepLocked(registration)
        clearTerminalLifecycleIndexLocked(for: registration)
        registrationsByObjectId.removeValue(forKey: registration.objectId)
        registeredObjectIdsBySurfaceId[registration.surfaceId]?.remove(registration.objectId)
        if registeredObjectIdsBySurfaceId[registration.surfaceId]?.isEmpty == true {
            registeredObjectIdsBySurfaceId.removeValue(forKey: registration.surfaceId)
        }
    }

    /// Replaces the process-generation index owned by `registration`.
    private func setTerminalLifecycleLocked(
        _ terminalLifecycleID: UUID,
        for registration: TerminalSurfaceWeakRegistration
    ) {
        clearTerminalLifecycleIndexLocked(for: registration)
        terminalLifecycleIdByObjectId[registration.objectId] = terminalLifecycleID
        registrationByTerminalLifecycleId[terminalLifecycleID] = registration
    }

    /// Removes a generation index only while `registration` still owns it.
    private func clearTerminalLifecycleIndexLocked(
        for registration: TerminalSurfaceWeakRegistration
    ) {
        guard let terminalLifecycleID = terminalLifecycleIdByObjectId.removeValue(
            forKey: registration.objectId
        ) else {
            return
        }
        if registrationByTerminalLifecycleId[terminalLifecycleID] === registration {
            registrationByTerminalLifecycleId.removeValue(forKey: terminalLifecycleID)
        }
    }

    /// Unlinks a registration from new traversals while preserving its next
    /// pointer for an in-flight traversal already parked on this entry.
    private func unlinkIncrementalTraversalRegistrationLocked(
        _ registration: TerminalSurfaceWeakRegistration
    ) {
        guard registration.isTraversalRegistered else { return }
        registration.isTraversalRegistered = false
        let previous = registration.previousTraversalRegistration
        let next = registration.nextTraversalRegistration
        if let previous {
            previous.nextTraversalRegistration = next
        } else if incrementalTraversalHead === registration {
            incrementalTraversalHead = next
        }
        next?.previousTraversalRegistration = previous
        registration.previousTraversalRegistration = nil
    }

    /// Adds a registration to the circular dead-entry sweep list.
    private func insertIntoDeadRegistrationSweepLocked(
        _ registration: TerminalSurfaceWeakRegistration
    ) {
        guard let cursorId = nextDeadRegistrationSweepObjectId,
              let cursor = registrationsByObjectId[cursorId],
              let tail = registrationsByObjectId[cursor.previousSweepObjectId] else {
            registration.previousSweepObjectId = registration.objectId
            registration.nextSweepObjectId = registration.objectId
            nextDeadRegistrationSweepObjectId = registration.objectId
            return
        }

        registration.previousSweepObjectId = tail.objectId
        registration.nextSweepObjectId = cursor.objectId
        tail.nextSweepObjectId = registration.objectId
        cursor.previousSweepObjectId = registration.objectId
    }

    /// Removes a registration from the circular dead-entry sweep list.
    private func removeFromDeadRegistrationSweepLocked(
        _ registration: TerminalSurfaceWeakRegistration
    ) {
        let previousId = registration.previousSweepObjectId
        let nextId = registration.nextSweepObjectId
        if nextId == registration.objectId {
            nextDeadRegistrationSweepObjectId = nil
            return
        }

        registrationsByObjectId[previousId]?.nextSweepObjectId = nextId
        registrationsByObjectId[nextId]?.previousSweepObjectId = previousId
        if nextDeadRegistrationSweepObjectId == registration.objectId {
            nextDeadRegistrationSweepObjectId = nextId
        }
    }

    /// Periodically prunes dead registrations so abandoned conformers cannot
    /// grow the identity ledger without bound.
    private func pruneAllDeadRegistrationsLocked() -> DeadRegistrationSweepResult {
        pruneDeadRegistrationsLocked(limit: registrationsByObjectId.count)
    }

    /// Inspects at most `limit` registrations, rotating the cursor so repeated
    /// calls eventually visit every live or abandoned registration.
    private func pruneDeadRegistrationsLocked(limit: Int) -> DeadRegistrationSweepResult {
        var remaining = min(limit, registrationsByObjectId.count)
        var removed = false
        var liveRegistrations: [LiveRegistrationSnapshot] = []
        liveRegistrations.reserveCapacity(remaining)
        while remaining > 0,
              let objectId = nextDeadRegistrationSweepObjectId,
              let registration = registrationsByObjectId[objectId] {
            nextDeadRegistrationSweepObjectId = registration.nextSweepObjectId
            if let surface = registration.surface {
                liveRegistrations.append((registration, surface))
            } else {
                removeRegistrationLocked(registration)
                generation &+= 1
                removed = true
            }
            remaining -= 1
        }
        return (liveRegistrations, removed)
    }

    /// Returns live registrations for an id after removing dead weak entries.
    private func liveRegistrationsLocked(
        for surfaceId: UUID
    ) -> (
        liveRegistrations: [LiveRegistrationSnapshot],
        removedDeadRegistration: Bool
    ) {
        guard let objectIds = registeredObjectIdsBySurfaceId[surfaceId] else {
            return ([], false)
        }
        var liveRegistrations: [LiveRegistrationSnapshot] = []
        liveRegistrations.reserveCapacity(objectIds.count)
        var removedDeadRegistration = false
        for objectId in objectIds {
            guard let registration = registrationsByObjectId[objectId] else {
                registeredObjectIdsBySurfaceId[surfaceId]?.remove(objectId)
                if registeredObjectIdsBySurfaceId[surfaceId]?.isEmpty == true {
                    registeredObjectIdsBySurfaceId.removeValue(forKey: surfaceId)
                }
                removedDeadRegistration = true
                continue
            }
            guard let surface = registration.surface else {
                removeRegistrationLocked(registration)
                generation &+= 1
                removedDeadRegistration = true
                continue
            }
            liveRegistrations.append((registration, surface))
        }
        return (liveRegistrations, removedDeadRegistration)
    }

    /// Returns a current surface only when its stable and generation identities agree.
    private func currentSurfaceLocked(
        terminalLifecycleID: UUID,
        matchingSurfaceID: UUID?
    ) -> LifecycleLookupResult {
        guard let registration = registrationByTerminalLifecycleId[terminalLifecycleID],
              registrationsByObjectId[registration.objectId] === registration,
              terminalLifecycleIdByObjectId[registration.objectId] == terminalLifecycleID,
              matchingSurfaceID == nil || registration.surfaceId == matchingSurfaceID else {
            return (nil, [], false)
        }
        let live = liveRegistrationsLocked(for: registration.surfaceId)
        let current = live.liveRegistrations.max(
            by: { $0.registration.sequence < $1.registration.sequence }
        )
        guard current?.registration === registration else {
            return (nil, live.liveRegistrations, live.removedDeadRegistration)
        }
        return (current?.surface, live.liveRegistrations, live.removedDeadRegistration)
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
            routeRetirer?.retireInactiveRecoverableMainWindowRoutes(
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

    /// The newest registered surface with the given id, if it is still alive.
    ///
    /// Surface replacement can briefly overlap the outgoing and incoming
    /// models under one logical id. Registration order is the ownership order:
    /// the newest live model is canonical until it unregisters, at which point
    /// the prior live registration is promoted.
    public func surface(id: UUID) -> (any TerminalSurfacing)? {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        let object = live.liveRegistrations
            .max(by: { $0.registration.sequence < $1.registration.sequence })?
            .surface
        lock.unlock()
        withExtendedLifetime(live.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return object
    }

    /// The current terminal process generation for a live surface identity.
    public func terminalLifecycleID(surfaceID: UUID) -> UUID? {
        lock.lock()
        let live = liveRegistrationsLocked(for: surfaceID)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        let terminalLifecycleID = live.liveRegistrations
            .max(by: { $0.registration.sequence < $1.registration.sequence })
            .flatMap { terminalLifecycleIdByObjectId[$0.registration.objectId] }
        lock.unlock()
        withExtendedLifetime(live.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return terminalLifecycleID
    }

    /// The current surface authenticated by a terminal-process generation.
    public func surface(
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        lock.lock()
        let lookup = currentSurfaceLocked(
            terminalLifecycleID: terminalLifecycleID,
            matchingSurfaceID: nil
        )
        let shouldScheduleRouteRetireSweep =
            lookup.removedDeadRegistration && claimRouteRetireSweepLocked()
        lock.unlock()
        withExtendedLifetime(lookup.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return lookup.surface
    }

    /// Atomically retrieves the current surface when both identities match.
    public func surface(
        id: UUID,
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        lock.lock()
        let lookup = currentSurfaceLocked(
            terminalLifecycleID: terminalLifecycleID,
            matchingSurfaceID: id
        )
        let shouldScheduleRouteRetireSweep =
            lookup.removedDeadRegistration && claimRouteRetireSweepLocked()
        lock.unlock()
        withExtendedLifetime(lookup.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return lookup.surface
    }

    /// Whether a current surface is registered for `id` and, when supplied,
    /// owns the terminal-process generation.
    public func isCurrentSurface(
        id: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool {
        lock.lock()
        let liveRegistrations: [LiveRegistrationSnapshot]
        let removedDeadRegistration: Bool
        let isCurrent: Bool
        if let terminalLifecycleID {
            let lookup = currentSurfaceLocked(
                terminalLifecycleID: terminalLifecycleID,
                matchingSurfaceID: id
            )
            liveRegistrations = lookup.liveRegistrations
            removedDeadRegistration = lookup.removedDeadRegistration
            isCurrent = lookup.surface != nil
        } else {
            let live = liveRegistrationsLocked(for: id)
            liveRegistrations = live.liveRegistrations
            removedDeadRegistration = live.removedDeadRegistration
            isCurrent = !live.liveRegistrations.isEmpty
        }
        let shouldScheduleRouteRetireSweep =
            removedDeadRegistration && claimRouteRetireSweepLocked()
        lock.unlock()
        withExtendedLifetime(liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return isCurrent
    }

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    public func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        let isRightSidebarDock = live.liveRegistrations
            .max(by: { $0.registration.sequence < $1.registration.sequence })?
            .registration.focusPlacement == .rightSidebarDock
        lock.unlock()
        withExtendedLifetime(live.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return isRightSidebarDock
    }

    /// Re-records the focus placement for an exact live surface registration.
    /// No-op when that registration is gone, so an outgoing model cannot
    /// mutate its replacement's placement.
    ///
    /// - Parameters:
    ///   - surface: The exact registered model whose placement changed.
    ///   - placement: The surface's new focus-routing placement.
    public func updateFocusPlacement(
        for surface: any TerminalSurfacing,
        _ placement: TerminalSurfaceFocusPlacement
    ) {
        lock.lock()
        let registration = registrationsByObjectId[ObjectIdentifier(surface)]
        let registeredSurface = registration?.surface
        guard let registration,
              registration.isTraversalRegistered,
              registeredSurface === surface else {
            lock.unlock()
            withExtendedLifetime(registeredSurface) {}
            return
        }
        registration.focusPlacement = placement
        lock.unlock()
        withExtendedLifetime(registeredSurface) {}
    }

    /// Re-records the canonical registration's placement for callers that
    /// only have a stable surface id.
    ///
    /// This compatibility API intentionally updates only the newest live
    /// registration, so an outgoing duplicate-id model cannot mutate its
    /// replacement.
    public func updateFocusPlacement(
        id: UUID,
        _ placement: TerminalSurfaceFocusPlacement
    ) {
        lock.lock()
        let live = liveRegistrationsLocked(for: id)
        let shouldScheduleRouteRetireSweep =
            live.removedDeadRegistration && claimRouteRetireSweepLocked()
        if let canonical = live.liveRegistrations.max(
            by: { $0.registration.sequence < $1.registration.sequence }
        ) {
            canonical.registration.focusPlacement = placement
        }
        lock.unlock()
        withExtendedLifetime(live.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
    }

    /// A bounded count snapshot for leak diagnostics and crash/app-hang telemetry.
    public func diagnosticSnapshot() -> TerminalSurfaceRegistryDiagnosticSnapshot {
        lock.lock()
        let sweep = pruneAllDeadRegistrationsLocked()
        let shouldScheduleRouteRetireSweep =
            sweep.removedDeadRegistration && claimRouteRetireSweepLocked()
        let runtimeSurfaceCount = runtimeSurfaceOwners.count
        var workspaceSurfaceCount = 0
        var rightSidebarDockSurfaceCount = 0
        for snapshot in sweep.liveRegistrations {
            switch snapshot.registration.focusPlacement {
            case .workspace:
                workspaceSurfaceCount += 1
            case .rightSidebarDock:
                rightSidebarDockSurfaceCount += 1
            }
        }
        lock.unlock()
        withExtendedLifetime(sweep.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)

        return TerminalSurfaceRegistryDiagnosticSnapshot(
            registeredSurfaceCount: sweep.liveRegistrations.count,
            workspaceSurfaceCount: workspaceSurfaceCount,
            rightSidebarDockSurfaceCount: rightSidebarDockSurfaceCount,
            runtimeSurfaceCount: runtimeSurfaceCount
        )
    }

    /// All live registered surfaces, ordered by id for stable iteration.
    public func allSurfaces() -> [any TerminalSurfacing] {
        allSurfacesUnordered().sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// All live registered surfaces without imposing an allocation-heavy UUID
    /// string ordering. Hot-path consumers that apply their own ranking should
    /// use this snapshot to avoid sorting the registry twice.
    public func allSurfacesUnordered() -> [any TerminalSurfacing] {
        lock.lock()
        let sweep = pruneAllDeadRegistrationsLocked()
        let shouldScheduleRouteRetireSweep =
            sweep.removedDeadRegistration && claimRouteRetireSweepLocked()
        let objects = sweep.liveRegistrations.map(\.surface)
        lock.unlock()
        withExtendedLifetime(sweep.liveRegistrations) {}
        scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
        return objects
    }

    /// Begins a weak traversal without materializing or sorting every surface.
    public func makeIncrementalTraversal()
        -> TerminalSurfaceRegistryIncrementalTraversal {
        lock.lock()
        let traversal =
            TerminalSurfaceRegistryIncrementalTraversal(
                registry: self,
                cursor: incrementalTraversalHead
            )
        lock.unlock()
        return traversal
    }

    /// Constant-time identity check for work captured by an incremental walk.
    public func isRegistered(
        _ surface: any TerminalSurfacing
    ) -> Bool {
        lock.lock()
        let registration = registrationsByObjectId[ObjectIdentifier(surface)]
        let registeredSurface = registration?.surface
        let isRegistered =
            registration?.isTraversalRegistered == true
            && registeredSurface === surface
        lock.unlock()
        withExtendedLifetime(registeredSurface) {}
        return isRegistered
    }

    func nextVisit(
        for traversal:
            TerminalSurfaceRegistryIncrementalTraversal
    ) -> TerminalSurfaceRegistryIncrementalVisit? {
        lock.lock()
        guard !traversal.isFinished else {
            lock.unlock()
            return nil
        }
        guard let registration = traversal.cursor else {
            traversal.isFinished = true
            lock.unlock()
            return nil
        }
        traversal.cursor = registration.nextTraversalRegistration
        guard registration.isTraversalRegistered else {
            lock.unlock()
            return TerminalSurfaceRegistryIncrementalVisit(surface: nil)
        }
        guard let surface = registration.surface else {
            var shouldScheduleRouteRetireSweep = false
            if registrationsByObjectId[registration.objectId] === registration {
                removeRegistrationLocked(registration)
                generation &+= 1
                shouldScheduleRouteRetireSweep = claimRouteRetireSweepLocked()
            }
            lock.unlock()
            scheduleRouteRetireSweepIfNeeded(shouldScheduleRouteRetireSweep)
            return TerminalSurfaceRegistryIncrementalVisit(surface: nil)
        }
        lock.unlock()
        return TerminalSurfaceRegistryIncrementalVisit(surface: surface)
    }
}
