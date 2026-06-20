public import Foundation
public import Bonsplit

/// The live-state seam ``SurfaceCreationCoordinator`` calls back through when it
/// orchestrates the terminal-config-inheritance walk for a freshly created
/// surface.
///
/// The inheritance walk is pure ordering and arithmetic over panel identities
/// (`UUID`), font points (`Float`), and the Sendable `CmuxSurfaceConfigTemplate`,
/// so it belongs in the package. The reads and writes it drives, however, are
/// app-target live state that cannot move until the workspace god model and its
/// `TerminalPanel` are themselves packaged (the Wave-4 decomposition): the
/// ordered candidate panels (which require reads of the bonsplit layout, the
/// workspace panel registry, and the focused/remembered panels), the per-panel
/// Ghostty surface probe (the C bridges `ghostty_surface_inherited_config` and
/// the runtime font-size probe, taken under one ARC pin), and the per-panel
/// lineage/font bookkeeping the workspace persists. The host owns all of that;
/// the coordinator owns only the decision of which candidate to use and how to
/// combine the font points.
///
/// The seam is intentionally coarse: one method gathers every live read for a
/// candidate (so the panel/surface are pinned exactly once, as the legacy body
/// did), and one method applies every write for the chosen candidate (in the
/// legacy order: seed lineage, remember the source, record the last-known font).
/// A conformer reproduces the legacy private `Workspace` helpers exactly:
/// `terminalPanelConfigInheritanceCandidates(preferredPanelId:inPane:)` (the
/// ordered candidate panel IDs), `inheritedTerminalConfig`'s per-candidate read
/// block, and the `terminalInheritanceFontPointsByPanelId` /
/// `lastTerminalConfigInheritanceFontPoints` /
/// `rememberTerminalConfigInheritanceSource` writes.
@MainActor
public protocol SurfaceCreationHosting: AnyObject {
    /// The candidate terminal panel IDs used as the inheritance source, already
    /// ordered by the workspace's priority rule (preferred panel, the preferred
    /// pane's selected terminal, the focused terminal, the last remembered
    /// source, the preferred pane's terminal tabs in order, then every terminal
    /// panel sorted by `id.uuidString`) and de-duplicated. Mirrors the legacy
    /// `Workspace.terminalPanelConfigInheritanceCandidates(preferredPanelId:inPane:)`
    /// mapped to `\.id`.
    func configInheritanceCandidatePanelIds(
        preferredPanelId: UUID?,
        inPane preferredPaneId: PaneID?
    ) -> [UUID]

    /// Gathers the three live reads for `panelId` under a single ARC pin of the
    /// panel and its Ghostty surface, or `nil` when the panel no longer exposes
    /// a live surface (the legacy walk skipped such a candidate via
    /// `guard let sourceSurface`). One call performs the
    /// `cmuxInheritedSurfaceConfig(sourceSurface:context:)` C bridge, the
    /// `terminalInheritanceFontPointsByPanelId[panelId]` lineage-root read, and
    /// the `cmuxCurrentSurfaceFontSizePoints` runtime probe, exactly as the
    /// legacy per-candidate block did inside one
    /// `withExtendedLifetime((terminalPanel, surface))`.
    func probeInheritanceCandidate(panelId: UUID) -> SurfaceInheritanceCandidateProbe?

    /// Applies the writes for the chosen live candidate, mirroring the legacy
    /// body's order and conditions exactly. When `rootedFontPoints` is non-`nil`
    /// (the coordinator resolved a positive lineage value) it seeds
    /// `terminalInheritanceFontPointsByPanelId[panelId]`; it then always calls
    /// `rememberTerminalConfigInheritanceSource(_:)`; and it records
    /// `finalConfigFontPoints` as `lastTerminalConfigInheritanceFontPoints` only
    /// when that value is positive.
    func commitInheritanceSelection(
        panelId: UUID,
        rootedFontPoints: Float?,
        finalConfigFontPoints: Float
    )

    /// The last-known inheritance font points used to synthesize a fallback
    /// config when no live candidate is found, mirroring the read of
    /// `lastTerminalConfigInheritanceFontPoints` in the legacy fallback branch.
    var lastKnownInheritanceFontPoints: Float? { get }

    /// Emits the DEBUG-only `zoom.inherit fallback=lastKnownFont …` log line the
    /// legacy fallback branch logged. A no-op in release builds.
    func logInheritanceFallback(fontPoints: Float)
}
