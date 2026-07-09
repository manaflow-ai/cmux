public import Foundation

/// Decides the config-inheritance source for a brand-new workspace from
/// pre-extracted value inputs: which existing terminal panel a new workspace
/// inherits its Ghostty config from, and the terminal font points it seeds.
///
/// This is the package-pure core of the legacy
/// `TabManager.terminalPanelForWorkspaceConfigInheritanceSource` and
/// `TabManager.cachedInheritedTerminalFontPointsForNewWorkspace` bodies. Both
/// were pure functions of value reads off the source `Workspace`, so the
/// app-side forwarders flatten those reads (through the
/// ``WorkspaceCreationInheritanceReading`` seam) into `Sendable` inputs, call
/// the matching decision here, and map the returned id back to the live
/// `TerminalPanel` via `workspace.terminalPanel(for:)`. Keeping the decisions
/// value-in/value-out lets the resolver avoid importing the app target's
/// `TerminalPanel`/`TerminalSurface` types, mirroring ``SurfaceReuseResolver``.
public struct WorkspaceCreationInheritanceResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Returns the id of the terminal panel a new workspace inherits its Ghostty
    /// config from, or `nil` when the source has no candidate panels.
    ///
    /// Lifts the legacy candidate ordering one-for-one: the remembered panel is
    /// the highest-priority candidate, followed by every terminal panel in the
    /// source's `id.uuidString`-sorted order, deduped by id (the legacy `seen`
    /// set). The first candidate whose surface is live is preferred; otherwise
    /// the first candidate is returned (the legacy `candidates.first(where:
    /// live) ?? candidates.first`).
    public func configInheritanceSourcePanelId(
        from source: WorkspaceConfigInheritancePanelSource
    ) -> UUID? {
        var candidates: [UUID] = []
        var seen: Set<UUID> = []

        if let rememberedPanelId = source.rememberedPanelId, seen.insert(rememberedPanelId).inserted {
            candidates.append(rememberedPanelId)
        }
        for panelId in source.orderedTerminalPanelIds where seen.insert(panelId).inserted {
            candidates.append(panelId)
        }

        if let livePanelId = candidates.first(where: { source.liveSurfacePanelIds.contains($0) }) {
            return livePanelId
        }
        return candidates.first
    }

    /// Returns the inherited terminal font points a new workspace seeds, or
    /// `nil` when there is no positive remembered font lineage.
    ///
    /// Lifts the legacy
    /// `cachedInheritedTerminalFontPointsForNewWorkspace` guard one-for-one: the
    /// remembered points must be present and strictly positive.
    public func inheritedTerminalFontPoints(rememberedFontPoints: Float?) -> Float? {
        guard let fontPoints = rememberedFontPoints, fontPoints > 0 else {
            return nil
        }
        return fontPoints
    }
}
