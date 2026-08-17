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
    // SAFETY: every read and write is guarded by `lock`; weak nodes prevent
    // the route index from extending a surface lifetime.
    nonisolated(unsafe) private var currentSurfaceNodesByID:
        [UUID: TerminalSurfaceRegistryWeakNode] = [:]
    // SAFETY: every read and write is guarded by `lock`; weak nodes prevent
    // lifecycle lookup from extending any registered surface lifetime.
    nonisolated(unsafe) private var surfaceNodesByTerminalLifecycleID:
        [UUID: TerminalSurfaceRegistryWeakNode] = [:]
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

    /// Registers a live surface, its process generation, and its focus placement.
    /// - Parameters:
    ///   - surface: The surface model being registered.
    ///   - terminalLifecycleID: The generation exported to its current child.
    public func register(
        _ surface: any TerminalSurfacing,
        terminalLifecycleID: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        surfaces.add(surface)
        let identity = ObjectIdentifier(surface)
        if let existingNode =
                incrementalTraversalNodes[identity],
           existingNode.isRegistered,
           existingNode.surface === surface {
            clearTerminalLifecycleIndex(for: existingNode)
            existingNode.terminalLifecycleID = terminalLifecycleID
            setCurrentSurfaceNode(existingNode)
            surfaceFocusPlacements[surface.id] =
                surface.focusPlacement
            generation &+= 1
            return
        }
        if let replacedNode =
            incrementalTraversalNodes.removeValue(
                forKey: identity
            ) {
            removeRegisteredNode(replacedNode)
        }
        let node = TerminalSurfaceRegistryWeakNode(
            surface: surface,
            terminalLifecycleID: terminalLifecycleID,
            next: incrementalTraversalHead
        )
        incrementalTraversalHead?.previous = node
        incrementalTraversalHead = node
        incrementalTraversalNodes[identity] = node
        setCurrentSurfaceNode(node)
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
        generation &+= 1
    }

    /// Atomically retires the registered surface's current process generation.
    /// - Parameter surface: The retained surface whose child is being replaced.
    /// - Returns: The generation identity for the surface's next child runtime.
    public func advanceTerminalLifecycle(
        for surface: any TerminalSurfacing
    ) -> UUID {
        let terminalLifecycleID = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard let node = incrementalTraversalNodes[
                  ObjectIdentifier(surface)
              ],
              node.isRegistered,
              node.surface === surface else {
            return terminalLifecycleID
        }
        clearTerminalLifecycleIndex(for: node)
        node.terminalLifecycleID = terminalLifecycleID
        surfaceNodesByTerminalLifecycleID[terminalLifecycleID] = node
        return terminalLifecycleID
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
            let wasCurrent = currentSurfaceNodesByID[surfaceId] === node
            removeRegisteredNode(node)
            if wasCurrent {
                _ = currentSurface(id: surfaceId)
            }
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
        let object = currentSurface(id: id)
        lock.unlock()
        return object
    }

    /// The current terminal process generation for a live surface identity.
    public func terminalLifecycleID(surfaceID: UUID) -> UUID? {
        lock.lock()
        let terminalLifecycleID = currentSurfaceNode(
            id: surfaceID
        )?.terminalLifecycleID
        lock.unlock()
        return terminalLifecycleID
    }

    /// The current surface authenticated by a terminal-process generation.
    public func surface(
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        lock.lock()
        let object = currentSurface(
            terminalLifecycleID: terminalLifecycleID,
            matchingSurfaceID: nil
        )
        lock.unlock()
        return object
    }

    /// Atomically retrieves the current surface when both identities match.
    public func surface(
        id: UUID,
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)? {
        lock.lock()
        let object = currentSurface(
            terminalLifecycleID: terminalLifecycleID,
            matchingSurfaceID: id
        )
        lock.unlock()
        return object
    }

    /// Whether a current surface is registered for `id` and, when supplied,
    /// owns the terminal-process generation.
    ///
    /// This synchronous check lets socket telemetry reject caller-supplied
    /// stale generations before they occupy the ordered mutation queue. The
    /// delivery path checks again because the surface can still be replaced
    /// after enqueue.
    ///
    /// - Parameters:
    ///   - id: The stable surface identity.
    ///   - terminalLifecycleID: The reported process generation, or `nil` for
    ///     a compatibility caller that only requires a live surface.
    /// - Returns: Whether the report targets the current registered surface.
    public func isCurrentSurface(
        id: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let terminalLifecycleID else {
            return currentSurfaceNode(id: id) != nil
        }
        return currentSurface(
            terminalLifecycleID: terminalLifecycleID,
            matchingSurfaceID: id
        ) != nil
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
                let wasCurrent =
                    currentSurfaceNodesByID[node.surfaceID] === node
                removeRegisteredNode(node)
                if wasCurrent {
                    _ = currentSurfaceNode(id: node.surfaceID)
                }
            }
            return TerminalSurfaceRegistryIncrementalVisit(
                surface: nil
            )
        }
        return TerminalSurfaceRegistryIncrementalVisit(
            surface: surface
        )
    }

    /// Returns the most recently registered live surface with `id`.
    /// Callers must hold `lock`.
    private func currentSurface(id: UUID) -> (any TerminalSurfacing)? {
        currentSurfaceNode(id: id)?.surface
    }

    /// Returns a retained current surface for one child generation.
    /// Callers must hold `lock`.
    private func currentSurface(
        terminalLifecycleID: UUID,
        matchingSurfaceID: UUID?
    ) -> (any TerminalSurfacing)? {
        guard let node = surfaceNodesByTerminalLifecycleID[
                  terminalLifecycleID
              ],
              node.isRegistered,
              node.terminalLifecycleID == terminalLifecycleID,
              matchingSurfaceID == nil
                || node.surfaceID == matchingSurfaceID else {
            return nil
        }
        guard let surface = node.surface else {
            let surfaceID = node.surfaceID
            let wasCurrent = currentSurfaceNodesByID[surfaceID] === node
            removeRegisteredNode(node)
            if wasCurrent {
                _ = currentSurfaceNode(id: surfaceID)
            }
            return nil
        }
        guard currentSurfaceNode(id: node.surfaceID) === node else {
            return nil
        }
        return surface
    }

    /// Returns the most recently registered live node with `id`.
    /// Callers must hold `lock`.
    private func currentSurfaceNode(
        id: UUID
    ) -> TerminalSurfaceRegistryWeakNode? {
        if let node = currentSurfaceNodesByID[id],
           node.isRegistered,
           node.surface != nil {
            setCurrentSurfaceNode(node)
            return node
        }
        if let node = currentSurfaceNodesByID[id] {
            if node.isRegistered, node.surface == nil {
                removeRegisteredNode(node)
            } else {
                clearCurrentSurfaceIndex(for: node)
            }
        }
        var node = incrementalTraversalHead
        while let current = node {
            let next = current.next
            if current.isRegistered, current.surface == nil {
                removeRegisteredNode(current)
                node = next
                continue
            }
            if current.isRegistered,
               current.surfaceID == id {
                setCurrentSurfaceNode(current)
                return current
            }
            node = next
        }
        currentSurfaceNodesByID.removeValue(forKey: id)
        return nil
    }

    /// Makes `node` the current registration for its stable surface identity.
    /// Callers must hold `lock`.
    private func setCurrentSurfaceNode(
        _ node: TerminalSurfaceRegistryWeakNode
    ) {
        currentSurfaceNodesByID[node.surfaceID] = node
        surfaceNodesByTerminalLifecycleID[
            node.terminalLifecycleID
        ] = node
    }

    /// Removes `node` from the current-owner index without unlinking it.
    /// Callers must hold `lock`.
    private func clearCurrentSurfaceIndex(
        for node: TerminalSurfaceRegistryWeakNode
    ) {
        if currentSurfaceNodesByID[node.surfaceID] === node {
            currentSurfaceNodesByID.removeValue(forKey: node.surfaceID)
        }
    }

    /// Removes `node`'s generation index only when it still owns that entry.
    /// Callers must hold `lock`.
    private func clearTerminalLifecycleIndex(
        for node: TerminalSurfaceRegistryWeakNode
    ) {
        if surfaceNodesByTerminalLifecycleID[
            node.terminalLifecycleID
        ] === node {
            surfaceNodesByTerminalLifecycleID.removeValue(
                forKey: node.terminalLifecycleID
            )
        }
    }

    /// Drops every registry index for `node` and unlinks its weak-list entry.
    /// Callers must hold `lock`.
    private func removeRegisteredNode(
        _ node: TerminalSurfaceRegistryWeakNode
    ) {
        guard node.isRegistered else { return }
        if incrementalTraversalNodes[node.identity] === node {
            incrementalTraversalNodes.removeValue(forKey: node.identity)
        }
        clearCurrentSurfaceIndex(for: node)
        clearTerminalLifecycleIndex(for: node)
        unlinkIncrementalTraversalNode(node)
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
