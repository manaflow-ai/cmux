public import CmuxTerminalCore

/// One bounded registry visit. `surface` is nil when its weak owner closed.
public struct TerminalSurfaceRegistryIncrementalVisit {
    /// The live surface for this registry node, or nil when its weak owner was
    /// released before the visit.
    public let surface: (any TerminalSurfacing)?

    init(surface: (any TerminalSurfacing)?) {
        self.surface = surface
    }
}
