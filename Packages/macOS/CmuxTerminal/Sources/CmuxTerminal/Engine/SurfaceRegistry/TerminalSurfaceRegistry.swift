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
    private let lock = NSLock()
    // SAFETY: every access is guarded by `lock`.
    nonisolated(unsafe) private let surfaces = NSHashTable<AnyObject>.weakObjects()
    // SAFETY: synchronous `deinit` callers cannot await an actor; `lock`
    // serializes every access from those callers and the main actor.
    nonisolated(unsafe) private var incrementalTraversalHead:
        TerminalSurfaceRegistryWeakNode?
    // SAFETY: synchronous `deinit` callers cannot await an actor; `lock`
    // serializes every access from those callers and the main actor.
    nonisolated(unsafe) private var incrementalTraversalNodes:
        [ObjectIdentifier: TerminalSurfaceRegistryWeakNode] = [:]
    // SAFETY: every access is guarded by `lock`. Values are weak nodes so the
    // index does not extend a surface lifetime.
    nonisolated(unsafe) private var canonicalSurfaceNodes:
        [UUID: TerminalSurfaceRegistryWeakNode] = [:]
    // SAFETY: every access is guarded by `lock`. Placement is recorded per
    // registration so removing a replacement can restore its predecessor.
    nonisolated(unsafe) private var surfaceFocusPlacementsByIdentity:
        [ObjectIdentifier: TerminalSurfaceFocusPlacement] = [:]
    // SAFETY: every access is guarded by `lock`.
    nonisolated(unsafe) private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    // SAFETY: every access is guarded by `lock`.
    nonisolated(unsafe) private var surfaceFocusPlacements: [UUID: TerminalSurfaceFocusPlacement] = [:]
    // SAFETY: every read and write is guarded by `lock`.
    nonisolated(unsafe) private var generation: UInt64 = 0
    // SAFETY: every access is guarded by `lock`.
    nonisolated(unsafe) private weak var routeRetirer: (any MainWindowRouteRetiring)?

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
        defer { lock.unlock() }
        surfaces.add(surface)
        let identity = ObjectIdentifier(surface)
        if let existingNode =
                incrementalTraversalNodes[identity],
           existingNode.isRegistered,
           existingNode.surface === surface {
            canonicalSurfaceNodes[surface.id] = existingNode
            surfaceFocusPlacementsByIdentity[identity] = surface.focusPlacement
            surfaceFocusPlacements[surface.id] = surface.focusPlacement
            generation &+= 1
            return
        }
        if let replacedNode =
            incrementalTraversalNodes.removeValue(
                forKey: identity
            ) {
            unlinkIncrementalTraversalNode(replacedNode)
            surfaceFocusPlacementsByIdentity.removeValue(forKey: identity)
        }
        let node = TerminalSurfaceRegistryWeakNode(
            surface: surface,
            next: incrementalTraversalHead
        )
        incrementalTraversalHead?.previous = node
        incrementalTraversalHead = node
        incrementalTraversalNodes[identity] = node
        canonicalSurfaceNodes[surface.id] = node
        surfaceFocusPlacementsByIdentity[identity] = surface.focusPlacement
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
        generation &+= 1
    }

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id, then asks the route retirer to sweep recoverable
    /// main-window routes.
    public func unregister(_ surface: any TerminalSurfacing) {
        lock.lock()
        let surfaceId = surface.id
        let identity = ObjectIdentifier(surface)
        surfaces.remove(surface)
        if let node = incrementalTraversalNodes.removeValue(
            forKey: identity
        ) {
            unlinkIncrementalTraversalNode(node)
        }
        surfaceFocusPlacementsByIdentity.removeValue(forKey: identity)
        if canonicalSurfaceNodes[surfaceId]?.identity == identity
            || canonicalSurfaceNodes[surfaceId]?.surface == nil {
            if let promoted = newestRegisteredNode(surfaceID: surfaceId) {
                canonicalSurfaceNodes[surfaceId] = promoted
                surfaceFocusPlacements[surfaceId] =
                    surfaceFocusPlacementsByIdentity[promoted.identity]
            } else {
                canonicalSurfaceNodes.removeValue(forKey: surfaceId)
                surfaceFocusPlacements.removeValue(forKey: surfaceId)
            }
        } else if canonicalSurfaceNodes[surfaceId] == nil {
            surfaceFocusPlacements.removeValue(forKey: surfaceId)
        }
        generation &+= 1
        let routeRetirer = routeRetirer
        lock.unlock()

        Task { @MainActor in
            routeRetirer?.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
                reason: "terminalSurface.unregister"
            )
        }
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
        defer { lock.unlock() }
        if let canonical = canonicalSurfaceNodes[id],
           canonical.isRegistered,
           let surface = canonical.surface {
            return surface
        }
        guard let promoted = newestRegisteredNode(surfaceID: id),
              let surface = promoted.surface else {
            canonicalSurfaceNodes.removeValue(forKey: id)
            surfaceFocusPlacements.removeValue(forKey: id)
            return nil
        }
        canonicalSurfaceNodes[id] = promoted
        surfaceFocusPlacements[id] = surfaceFocusPlacementsByIdentity[promoted.identity]
        return surface
    }

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    public func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceFocusPlacements[id] == .rightSidebarDock
    }

    /// Re-records the focus placement for a live surface that moved between the
    /// workspace area and the right-sidebar dock. No-op when the id is not
    /// currently registered, so a stale move cannot resurrect a dropped entry.
    public func updateFocusPlacement(id: UUID, _ placement: TerminalSurfaceFocusPlacement) {
        lock.lock()
        defer { lock.unlock() }
        guard let canonical = canonicalSurfaceNodes[id],
              canonical.isRegistered,
              canonical.surface != nil else { return }
        surfaceFocusPlacementsByIdentity[canonical.identity] = placement
        surfaceFocusPlacements[id] = placement
    }

    /// A bounded count snapshot for leak diagnostics and crash/app-hang telemetry.
    public func diagnosticSnapshot() -> TerminalSurfaceRegistryDiagnosticSnapshot {
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? any TerminalSurfacing }
        let runtimeSurfaceCount = runtimeSurfaceOwners.count
        var workspaceSurfaceCount = 0
        var rightSidebarDockSurfaceCount = 0
        for object in objects {
            switch surfaceFocusPlacements[object.id] {
            case .workspace:
                workspaceSurfaceCount += 1
            case .rightSidebarDock:
                rightSidebarDockSurfaceCount += 1
            case .none:
                break
            }
        }
        lock.unlock()

        return TerminalSurfaceRegistryDiagnosticSnapshot(
            registeredSurfaceCount: objects.count,
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
        let objects = surfaces.allObjects.compactMap { $0 as? any TerminalSurfacing }
        lock.unlock()
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
        defer { lock.unlock() }
        guard let node =
                incrementalTraversalNodes[
                    ObjectIdentifier(surface)
                ],
              node.isRegistered else {
            return false
        }
        return node.surface === surface
    }

    func nextVisit(
        for traversal:
            TerminalSurfaceRegistryIncrementalTraversal
    ) -> TerminalSurfaceRegistryIncrementalVisit? {
        lock.lock()
        defer { lock.unlock() }
        guard !traversal.isFinished else {
            return nil
        }
        guard let node = traversal.cursor else {
            traversal.isFinished = true
            return nil
        }
        traversal.cursor = node.next
        guard node.isRegistered, let surface = node.surface else {
            if node.isRegistered {
                if incrementalTraversalNodes[node.identity] === node {
                    incrementalTraversalNodes.removeValue(
                        forKey: node.identity
                    )
                }
                unlinkIncrementalTraversalNode(node)
            }
            return TerminalSurfaceRegistryIncrementalVisit(
                surface: nil
            )
        }
        return TerminalSurfaceRegistryIncrementalVisit(
            surface: surface
        )
    }

    private func unlinkIncrementalTraversalNode(
        _ node: TerminalSurfaceRegistryWeakNode
    ) {
        guard node.isRegistered else { return }
        node.isRegistered = false
        let previous = node.previous
        let next = node.next
        if let previous {
            previous.next = next
        } else if incrementalTraversalHead === node {
            incrementalTraversalHead = next
        }
        next?.previous = previous
        node.previous = nil
        // Preserve `next` for traversals already parked on this node.
    }

    private func newestRegisteredNode(
        surfaceID: UUID
    ) -> TerminalSurfaceRegistryWeakNode? {
        var node = incrementalTraversalHead
        while let current = node {
            if current.isRegistered,
               let surface = current.surface,
               surface.id == surfaceID {
                return current
            }
            node = current.next
        }
        return nil
    }
}
