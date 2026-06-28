/// The read-only seam the app target's `Workspace` god object fulfills so the
/// package-pure ``WorkspaceCreationInheritanceResolver`` can decide a new
/// workspace's config-inheritance source without reaching into live AppKit /
/// Ghostty state.
///
/// The app-side witness flattens the live god state (the remembered
/// config-inheritance panel, the workspace's terminal panels, their live-surface
/// flags, and the remembered terminal font lineage) into the `Sendable` value
/// inputs the resolver consumes, mirroring how ``SurfaceInheritanceCandidateProbe``
/// captures a candidate's live reads under one ARC pin. The shape lives here,
/// next to the resolver that reads it, so the flattening boundary is owned by
/// the package even though the only conformer (`Workspace`) and the only
/// consumer (the per-window `TabManager` forwarders) live in the app target.
@MainActor
public protocol WorkspaceCreationInheritanceReading {
    /// The flattened terminal-panel snapshot used to choose a new workspace's
    /// config-inheritance source panel (legacy
    /// `terminalPanelForWorkspaceConfigInheritanceSource` reads).
    var configInheritancePanelSource: WorkspaceConfigInheritancePanelSource { get }

    /// The remembered terminal font points for config inheritance, or `nil`
    /// (legacy `lastRememberedTerminalFontPointsForConfigInheritance()`). The
    /// resolver applies the positive guard.
    var rememberedTerminalFontPointsForConfigInheritance: Float? { get }
}
