public import CmuxTerminalCore
internal import GhosttyKit

extension TerminalSurface {
    /// Adjusts this terminal's runtime font size and records an explicit override.
    ///
    /// Live surfaces delegate to Ghostty's native font-size action. Suspended or
    /// deferred surfaces update their durable lineage directly so the change is
    /// applied when their runtime is created again.
    ///
    /// - Parameters:
    ///   - deltaRuntimePoints: Point-size change after global magnification.
    ///   - fallbackRuntimePoints: Current configured runtime size to use when a
    ///     deferred surface has never reported font-size lineage.
    /// - Returns: Whether a live action ran or durable lineage was updated.
    @MainActor
    @discardableResult
    public func adjustFontSize(
        byRuntimePoints deltaRuntimePoints: Float32,
        fallbackRuntimePoints: Float32? = nil
    ) -> Bool {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return false }

        if let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "fontSize.adjust") {
            if let currentRuntimePoints =
                    GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(runtimeSurface),
               currentRuntimePoints.isFinite {
                if deltaRuntimePoints < 0,
                   currentRuntimePoints <= TerminalFontSizePolicy.minimumRuntimePoints {
                    return false
                }
                if deltaRuntimePoints > 0,
                   currentRuntimePoints >= TerminalFontSizePolicy.maximumRuntimePoints {
                    return false
                }
            }
            let verb = deltaRuntimePoints > 0 ? "increase_font_size" : "decrease_font_size"
            let action = "\(verb):\(abs(deltaRuntimePoints))"
            guard performExplicitInputBindingAction(action) else { return false }
            followsConfiguredFontSize = false
            _ = fontSizeLineageSnapshot()
            return true
        }

        let percent = globalFontMagnificationPercent()
        let currentRuntimePoints: Float32
        // After one native lifetime, non-explicit lineage is descendant-only;
        // this surface itself follows the current configured fallback.
        if !followsConfiguredFontSize,
           let lineage = lastKnownFontSizeLineage,
           lineage.isExplicitOverride || runtimeSurfaceGeneration == 0 {
            currentRuntimePoints = CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: lineage.basePoints,
                percent: percent
            )
        } else if let fallbackRuntimePoints,
                  fallbackRuntimePoints.isFinite,
                  fallbackRuntimePoints > 0 {
            currentRuntimePoints = fallbackRuntimePoints
        } else {
            return false
        }

        let adjustedRuntimePoints = TerminalFontSizePolicy().clampedRuntimePoints(
            currentRuntimePoints + deltaRuntimePoints
        )
        guard adjustedRuntimePoints != currentRuntimePoints else { return false }
        followsConfiguredFontSize = false
        recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                    fromRuntimePoints: adjustedRuntimePoints,
                    percent: percent
                ),
                isExplicitOverride: true
            )
        )
        return true
    }

    /// Resets this terminal to the current configured runtime font size.
    ///
    /// Live surfaces use Ghostty's font-only reset action. Ghostty refreshes
    /// that action's baseline during normal config reloads, so reset does not
    /// need a full surface-config update. Suspended or deferred surfaces clear
    /// their durable override so future runtimes follow terminal configuration.
    ///
    /// - Parameter configuredRuntimePoints: Current configured size after
    ///   global magnification.
    /// - Returns: Whether the live reset ran or durable lineage was updated.
    @MainActor
    @discardableResult
    public func resetFontSize(toConfiguredRuntimePoints configuredRuntimePoints: Float32) -> Bool {
        guard configuredRuntimePoints.isFinite, configuredRuntimePoints > 0 else { return false }

        let targetRuntimePoints = TerminalFontSizePolicy().clampedRuntimePoints(
            configuredRuntimePoints
        )
        let targetLineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: targetRuntimePoints,
                percent: globalFontMagnificationPercent()
            ),
            isExplicitOverride: false
        )

        if liveSurfaceForGhosttyAccess(reason: "fontSize.reset") != nil {
            guard performExplicitInputBindingAction("reset_font_size") else { return false }
            followsConfiguredFontSize = true
            recordCurrentFontSizeLineage(targetLineage)
            _ = fontSizeLineageSnapshot()
            return true
        }

        followsConfiguredFontSize = true
        recordCurrentFontSizeLineage(targetLineage)
        return true
    }

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
        followsConfiguredFontSize = !isExplicitOverride

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
        if lineage.isExplicitOverride {
            followsConfiguredFontSize = false
        }
        guard lastKnownFontSizeLineage != lineage else { return }
        lastKnownFontSizeLineage = lineage
        onFontSizeLineageChanged?(lineage)
    }

    /// Resolves the Swift-owned template used to create this surface's runtime.
    ///
    /// Initial non-explicit lineage seeds the first native runtime. After a
    /// native lifetime, non-explicit lineage remains available to descendants
    /// but must not seed this surface again because Cmd+0 and ordinary unzoomed
    /// terminals follow the then-current terminal config.
    @MainActor
    func runtimeCreationConfigTemplate() -> CmuxSurfaceConfigTemplate {
        var template = configTemplate ?? CmuxSurfaceConfigTemplate()
        if followsConfiguredFontSize
            || (
                lastKnownFontSizeLineage?.isExplicitOverride == false
                    && runtimeSurfaceGeneration > 0
            ) {
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
              TerminalFontSizePolicy().acceptsPersistedBasePoints(lineage.basePoints) else {
            return nil
        }
        return lineage.basePoints
    }
}
