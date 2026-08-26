public import CmuxTerminalCore

/// A weak, incremental view of registered surfaces.
///
/// Each call retains only the returned surface for that call. Surfaces
/// registered after traversal starts are excluded by its fixed head snapshot,
/// while closed or deallocated surfaces are skipped without materializing the
/// registry.
public final class TerminalSurfaceRegistryIncrementalTraversal {
    let registry: TerminalSurfaceRegistry
    var cursor: TerminalSurfaceWeakRegistration?
    var isFinished = false

    init(
        registry: TerminalSurfaceRegistry,
        cursor: TerminalSurfaceWeakRegistration?
    ) {
        self.registry = registry
        self.cursor = cursor
    }

    /// Visits exactly one registry node, including a released weak node.
    public func nextVisit()
        -> TerminalSurfaceRegistryIncrementalVisit? {
        registry.nextVisit(for: self)
    }

    /// Convenience iteration over live surfaces.
    public func next() -> (any TerminalSurfacing)? {
        while let visit = nextVisit() {
            if let surface = visit.surface {
                return surface
            }
        }
        return nil
    }
}
