public import Foundation
public import Observation

/// The per-workspace terminal config-inheritance font-points sub-model: owns the
/// per-panel inherited zoom lineage and the last-inheritance-source memory the
/// legacy `Workspace` god object kept as loose stored properties
/// (`terminalInheritanceFontPointsByPanelId`,
/// `lastTerminalConfigInheritancePanelId`,
/// `lastTerminalConfigInheritanceFontPoints`).
///
/// When a terminal panel is created, its inherited Ghostty config font size is
/// seeded into the per-panel map so descendant splits reuse the same root zoom
/// unless the user re-zooms. When a terminal panel is used as an inheritance
/// source (typically the last focused terminal), the workspace remembers its id
/// and its current font points so a later split can fall back to that value when
/// no live source surface is available.
///
/// This model is pure value storage: it holds only `Sendable` value types
/// (`UUID`, `Float`) and contains no host seam. The two app-coupled reads the
/// legacy bodies made — the live `TerminalPanel.surface.surface` and
/// `cmuxCurrentSurfaceFontSizePoints(_:)` — stay app-side; `Workspace` resolves
/// the runtime font points and passes them into ``remember(panelId:runtimePoints:)``,
/// and resolves the inherited config font size and passes it into
/// ``seed(panelId:fontPoints:)``. The candidate-walk host-seam path reads the
/// per-panel map through ``rootedFontPoints(forPanelId:)``.
///
/// `Workspace` owns one instance and forwards each former method and stored-state
/// access through a one-line call, so every call site stays byte-identical.
@MainActor
@Observable
public final class TerminalConfigInheritanceModel {
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user. Faithful lift of
    /// `Workspace.terminalInheritanceFontPointsByPanelId`.
    public var fontPointsByPanelId: [UUID: Float] = [:]

    /// Last terminal panel used as an inheritance source (typically last focused
    /// terminal). Faithful lift of `Workspace.lastTerminalConfigInheritancePanelId`.
    public var lastSourcePanelId: UUID?

    /// Last known terminal font points from inheritance sources. Used as fallback
    /// when no live terminal surface is currently available. Faithful lift of
    /// `Workspace.lastTerminalConfigInheritanceFontPoints`.
    public var lastSourceFontPoints: Float?

    /// Creates an empty model.
    public init() {}

    /// Seeds the per-panel inherited font points for a newly created panel from
    /// its resolved inherited config font size, and records it as the last known
    /// inheritance font points. A non-positive or absent `fontPoints` is ignored.
    /// Faithful lift of `Workspace.seedTerminalInheritanceFontPoints(panelId:configTemplate:)`;
    /// the `configTemplate?.fontSize` read stays app-side and the resolved value
    /// is passed in.
    public func seed(panelId: UUID, fontPoints: Float?) {
        guard let fontPoints, fontPoints > 0 else { return }
        fontPointsByPanelId[panelId] = fontPoints
        lastSourceFontPoints = fontPoints
    }

    /// Remembers `panelId` as the last inheritance source and, when the workspace
    /// could resolve the panel's live runtime font points, updates the per-panel
    /// map (only on a meaningful change) and the last-known font points. Faithful
    /// lift of `Workspace.rememberTerminalConfigInheritanceSource(_:)`; the live
    /// `TerminalPanel.surface.surface` read and `cmuxCurrentSurfaceFontSizePoints(_:)`
    /// stay app-side and the resolved `runtimePoints` is passed in (`nil` when the
    /// source surface was unavailable, matching the legacy body's skip).
    public func remember(panelId: UUID, runtimePoints: Float?) {
        lastSourcePanelId = panelId
        guard let runtimePoints else { return }
        let existing = fontPointsByPanelId[panelId]
        if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
            fontPointsByPanelId[panelId] = runtimePoints
        }
        lastSourceFontPoints = fontPointsByPanelId[panelId] ?? runtimePoints
    }

    /// The last known terminal font points from inheritance sources, used as the
    /// fallback when no live source surface is available. Faithful lift of
    /// `Workspace.lastRememberedTerminalFontPointsForConfigInheritance()`.
    public func lastRememberedFontPoints() -> Float? {
        lastSourceFontPoints
    }

    /// The rooted inherited font points recorded for `panelId`, or `nil` when the
    /// panel has no lineage entry. The candidate-walk host-seam path reads this.
    public func rootedFontPoints(forPanelId panelId: UUID) -> Float? {
        fontPointsByPanelId[panelId]
    }

    /// Records the rooted inherited font points for `panelId` (the candidate-walk
    /// commit path).
    public func setRootedFontPoints(_ fontPoints: Float, forPanelId panelId: UUID) {
        fontPointsByPanelId[panelId] = fontPoints
    }

    /// Drops the lineage entry for `panelId` (panel close / replacement paths).
    public func removeFontPoints(forPanelId panelId: UUID) {
        fontPointsByPanelId.removeValue(forKey: panelId)
    }

    /// Clears all per-panel lineage and last-source memory (workspace teardown).
    public func reset() {
        fontPointsByPanelId.removeAll(keepingCapacity: false)
        lastSourcePanelId = nil
        lastSourceFontPoints = nil
    }
}
