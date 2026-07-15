/// A persisted override for orientation-driven unified or split rendering.
public enum DiffLayoutOverride: String, Sendable, Codable, CaseIterable, Hashable {
    /// Uses unified portrait rendering and split landscape rendering.
    case automatic
    /// Always uses the unified diff layout.
    case unified
    /// Always uses the side-by-side diff layout.
    case split

    /// Resolves the concrete render mode for the current orientation.
    /// - Parameter isLandscape: Whether the available diff region is wider than it is tall.
    /// - Returns: The effective unified or split mode.
    public func renderMode(isLandscape: Bool) -> DiffRenderMode {
        switch self {
        case .automatic:
            isLandscape ? .split : .unified
        case .unified:
            .unified
        case .split:
            .split
        }
    }
}
