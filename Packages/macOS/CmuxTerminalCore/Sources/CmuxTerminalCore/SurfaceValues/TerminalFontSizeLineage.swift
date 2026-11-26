/// A terminal font size together with whether it is a surface-local override.
///
/// Keeping provenance beside the point size lets inherited and restored
/// surfaces preserve explicit zoom while terminals at the config default keep
/// following later config changes.
public struct TerminalFontSizeLineage: Equatable, Sendable {
    /// The unscaled font size in points at 100% global magnification.
    public var basePoints: Float32

    /// Whether the size came from an explicit surface-local zoom.
    public var isExplicitOverride: Bool

    /// Creates font-size lineage for a terminal surface.
    ///
    /// - Parameters:
    ///   - basePoints: The unscaled font size in points.
    ///   - isExplicitOverride: Whether the surface owns this size instead of
    ///     following the current terminal config.
    public init(basePoints: Float32, isExplicitOverride: Bool) {
        self.basePoints = basePoints
        self.isExplicitOverride = isExplicitOverride
    }
}
