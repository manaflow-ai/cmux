public import CmuxTerminalCore

/// The live reads the workspace performs for one inheritance-source candidate,
/// gathered under a single ARC pin of the candidate panel and its Ghostty
/// surface.
///
/// The legacy `Workspace.inheritedTerminalConfig` body extracted all three of
/// these values from one `withExtendedLifetime((terminalPanel, surface))` block
/// per candidate: the inherited Ghostty config (`cmuxInheritedSurfaceConfig`),
/// the panel's recorded lineage-root font points
/// (`terminalInheritanceFontPointsByPanelId[id]`), and the surface's runtime
/// zoom (`cmuxCurrentSurfaceFontSizePoints`). Returning them together as one
/// value keeps the package's `SurfaceCreationCoordinator` doing the pure
/// arithmetic while the host pins the panel/surface exactly once per candidate,
/// matching the legacy single-pin rather than re-resolving the panel for each
/// read.
public struct SurfaceInheritanceCandidateProbe: Sendable {
    /// The inherited Ghostty config read from the candidate's live surface
    /// (`cmuxInheritedSurfaceConfig(sourceSurface:context:)` with the split
    /// context).
    public var inheritedConfig: CmuxSurfaceConfigTemplate

    /// The candidate panel's recorded lineage-root font points, or
    /// `nil`/non-positive when no root has been seeded.
    public var rootedFontPoints: Float?

    /// The candidate surface's runtime zoom font points
    /// (`cmuxCurrentSurfaceFontSizePoints`), or `nil` when unavailable.
    public var runtimeFontPoints: Float?

    /// Creates a probe from the three live reads taken under one ARC pin.
    public init(
        inheritedConfig: CmuxSurfaceConfigTemplate,
        rootedFontPoints: Float?,
        runtimeFontPoints: Float?
    ) {
        self.inheritedConfig = inheritedConfig
        self.rootedFontPoints = rootedFontPoints
        self.runtimeFontPoints = runtimeFontPoints
    }
}
