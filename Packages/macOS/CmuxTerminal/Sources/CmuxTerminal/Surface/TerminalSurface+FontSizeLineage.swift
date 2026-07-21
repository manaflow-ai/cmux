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

        return recordObservedFontSizeLineage(
            runtimePoints: runtimePoints,
            isExplicitOverride: ghostty_surface_font_size_adjusted(runtimeSurface),
            globalFontMagnificationPercent: globalFontMagnificationPercent()
        )
    }

    /// Reconciles observed runtime points with durable surface ownership.
    ///
    /// A live value matching the active mobile fit is temporary and leaves the
    /// pre-fit lineage unchanged. A different live value came from outside the
    /// fitter, so it becomes the new durable base and restore point.
    @MainActor
    func recordObservedFontSizeLineage(
        runtimePoints: Float32,
        isExplicitOverride: Bool,
        globalFontMagnificationPercent: Int
    ) -> TerminalFontSizeLineage? {
        guard runtimePoints.isFinite, runtimePoints > 0 else {
            return lastKnownFontSizeLineage
        }
        if var fitState = mobileViewportFontFitState {
            guard !isExplicitOverride
                    || !fitState.matchesFittedRuntimePointSize(runtimePoints) else {
                return lastKnownFontSizeLineage
            }
            fitState.rebase(to: runtimePoints)
            mobileViewportFontFitState = fitState
        }

        let lineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: runtimePoints,
                percent: globalFontMagnificationPercent
            ),
            isExplicitOverride: isExplicitOverride
        )
        recordCurrentFontSizeLineage(lineage)
        return lineage
    }

    /// Records live font-size lineage for hibernation and split inheritance.
    ///
    /// A non-explicit value is retained as the last known split-inheritance
    /// value, while separately recording that this surface must follow current
    /// config when its own runtime is recreated.
    @MainActor
    func recordCurrentFontSizeLineage(_ lineage: TerminalFontSizeLineage) {
        lastKnownFontSizeLineage = lineage
    }

    /// Resolves the Swift-owned template used to create this surface's runtime.
    ///
    /// Live non-explicit lineage remains available to descendants, but must not
    /// seed this surface after hibernation because Cmd+0 and ordinary unzoomed
    /// terminals follow the then-current terminal config.
    @MainActor
    func runtimeCreationConfigTemplate() -> CmuxSurfaceConfigTemplate {
        var template = configTemplate ?? CmuxSurfaceConfigTemplate()
        if lastKnownFontSizeLineage?.isExplicitOverride == false {
            template.fontSizeLineage = nil
        } else if let lastKnownFontSizeLineage {
            template.fontSizeLineage = lastKnownFontSizeLineage
        }
        return template
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
