public import CmuxTerminalCore

/// One bounded registry visit. `surface` is nil when its weak owner closed.
public struct TerminalSurfaceRegistryIncrementalVisit {
    /// Stable identity for this registry node, even after its weak surface has
    /// been released.
    public let identity: ObjectIdentifier

    /// The live surface for this registry node, or nil when its weak owner was
    /// released before the visit.
    public let surface: (any TerminalSurfacing)?

    init(
        identity: ObjectIdentifier,
        surface: (any TerminalSurfacing)?
    ) {
        self.identity = identity
        self.surface = surface
    }
}
