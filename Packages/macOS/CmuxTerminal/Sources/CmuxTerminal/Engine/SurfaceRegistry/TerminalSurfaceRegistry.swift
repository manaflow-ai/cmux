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
            surfaceFocusPlacements[surface.id] =
                surface.focusPlacement
            generation &+= 1
            return
        }
        if let replacedNode =
            incrementalTraversalNodes.removeValue(
                forKey: identity
            ) {
            unlinkIncrementalTraversalNode(replacedNode)
        }
        let node = TerminalSurfaceRegistryWeakNode(
            surface: surface,
            next: incrementalTraversalHead
        )
        incrementalTraversalHead?.previous = node
        incrementalTraversalHead = node
        incrementalTraversalNodes[identity] = node
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
        generation &+= 1
    }

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id, then asks the route retirer to sweep recoverable
    /// main-window routes.
    public func unregister(_ surface: any TerminalSurfacing) {
        lock.lock()
        let surfaceId = surface.id
        surfaces.remove(surface)
        if let node = incrementalTraversalNodes.removeValue(
            forKey: ObjectIdentifier(surface)
        ) {
            unlinkIncrementalTraversalNode(node)
        }
        let stillRegistered = surfaces.allObjects
            .compactMap { $0 as? any TerminalSurfacing }
            .contains { $0 !== surface && $0.id == surfaceId }
        if !stillRegistered {
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

    /// The registered surface with the given id, if it is still alive.
    public func surface(id: UUID) -> (any TerminalSurfacing)? {
        lock.lock()
        let object = surfaces.allObjects
            .compactMap { $0 as? any TerminalSurfacing }
            .first { $0.id == id }
        lock.unlock()
        return object
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
        guard surfaceFocusPlacements[id] != nil else { return }
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
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? any TerminalSurfacing }
        lock.unlock()
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
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
}
