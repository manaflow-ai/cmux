public import CmuxTerminalCore
internal import GhosttyKit

extension TerminalSurface {
    /// Captures the current font size and its surface-local ownership state.
    ///
    /// Live Ghostty state is authoritative. When the runtime is unavailable,
    /// the last captured lineage survives hibernation and session restoration.
    ///
    /// - Returns: Current font-size lineage, or nil before a size is known.
    @MainActor
    public func fontSizeLineageSnapshot() -> TerminalFontSizeLineage? {
        guard let runtimeSurface = liveSurfaceForGhosttyAccess(
            reason: "fontSizeLineage.snapshot"
        ) else {
            return lastKnownFontSizeLineage
        }
        guard let runtimePoints = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
            runtimeSurface
        ) else {
            return lastKnownFontSizeLineage
        }

        let lineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: runtimePoints,
                percent: globalFontMagnificationPercent()
            ),
            isExplicitOverride: ghostty_surface_font_size_adjusted(runtimeSurface)
        )
        if lineage.isExplicitOverride || configTemplate?.fontSizeLineage?.isExplicitOverride == true {
            // Keep an unadjusted value only as a tombstone for a restored or
            // inherited explicit override that Cmd+0 cleared. Ordinary
            // unzoomed surfaces should keep following current config when a
            // hibernated runtime is recreated.
            lastKnownFontSizeLineage = lineage
        } else {
            lastKnownFontSizeLineage = nil
        }
        return lineage
    }

    /// Returns the explicit unscaled font override to persist in a session snapshot.
    ///
    /// Nil means the terminal follows the current config and should not pin a
    /// font size across relaunches.
    @MainActor
    public func sessionFontSizeOverrideBasePoints() -> Float32? {
        guard let lineage = fontSizeLineageSnapshot(),
              lineage.isExplicitOverride,
              lineage.basePoints.isFinite,
              lineage.basePoints > 0 else {
            return nil
        }
        return lineage.basePoints
    }
}
