public import CmuxTerminalCore
public import Foundation
internal import GhosttyKit

extension TerminalSurface {
    /// Marks that a higher-level batched font-size request already contributed
    /// to this surface's lineage. New descendants can carry the same request
    /// provenance without inferring ownership from a colliding point value.
    @MainActor
    public func markFontSizeChangeApplied(token: UUID) {
        lastAppliedFontSizeChangeToken = token
    }

    /// Returns whether this surface's lineage already includes `token`.
    @MainActor
    public func hasAppliedFontSizeChange(token: UUID) -> Bool {
        lastAppliedFontSizeChangeToken == token
    }

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
        adjustFontSize(
            byOrderedRuntimePointDeltas: [deltaRuntimePoints],
            fallbackRuntimePoints: fallbackRuntimePoints
        )
    }

    /// Applies ordered point-size runs while rebuilding the live font once.
    ///
    /// Each run clamps independently to Ghostty's native range. This preserves
    /// input order at the bounds, then sends only the final net delta to a live
    /// surface so auto-repeat batching cannot rebuild the font for every event.
    @MainActor
    @discardableResult
    public func adjustFontSize(
        byOrderedRuntimePointDeltas orderedRuntimePointDeltas: [Float32],
        fallbackRuntimePoints: Float32? = nil
    ) -> Bool {
        guard !orderedRuntimePointDeltas.isEmpty,
              orderedRuntimePointDeltas.allSatisfy(\.isFinite) else {
            return false
        }
        let orderedRuntimePointDeltas = orderedRuntimePointDeltas.filter { $0 != 0 }
        guard !orderedRuntimePointDeltas.isEmpty else { return false }

        let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "fontSize.adjust")
        let percent = globalFontMagnificationPercent()
        let currentRuntimePoints: Float32
        if let runtimeSurface,
           let observedRuntimePoints =
                GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(runtimeSurface) {
            currentRuntimePoints = observedRuntimePoints
        } else if !followsConfiguredFontSize,
           let lineage = lastKnownFontSizeLineage,
           lineage.isExplicitOverride || runtimeSurfaceGeneration == 0 {
            // After one native lifetime, non-explicit lineage is descendant-only;
            // this surface itself follows the current configured fallback.
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

        let policy = TerminalFontSizePolicy()
        let boundedCurrentRuntimePoints = policy.clampedRuntimePoints(currentRuntimePoints)
        let adjustedRuntimePoints = orderedRuntimePointDeltas.reduce(
            boundedCurrentRuntimePoints
        ) { current, delta in
            policy.clampedRuntimePoints(current + delta)
        }
        let netRuntimePointDelta = adjustedRuntimePoints - boundedCurrentRuntimePoints
        guard netRuntimePointDelta != 0 else { return false }

        if runtimeSurface != nil {
            let verb = netRuntimePointDelta > 0
                ? "increase_font_size"
                : "decrease_font_size"
            let action = "\(verb):\(abs(netRuntimePointDelta))"
            guard performExplicitInputBindingAction(action) else { return false }
            followsConfiguredFontSize = false
            _ = fontSizeLineageSnapshot()
            return true
        }

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

        if let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "fontSize.reset") {
            let nativeIsExplicitOverride =
                ghostty_surface_font_size_adjusted(runtimeSurface)
            let observedRuntimePoints =
                GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(runtimeSurface)
            let nativeMatchesTarget = observedRuntimePoints.map {
                abs($0 - targetRuntimePoints) < 0.000_1
            } ?? followsConfiguredFontSize
            if !nativeIsExplicitOverride, nativeMatchesTarget {
                let durableStateChanged =
                    !followsConfiguredFontSize
                    || lastKnownFontSizeLineage.map { $0 != targetLineage } == true
                followsConfiguredFontSize = true
                if lastKnownFontSizeLineage != nil {
                    recordCurrentFontSizeLineage(targetLineage)
                }
                return durableStateChanged
            }

            guard performExplicitInputBindingAction("reset_font_size") else { return false }
            followsConfiguredFontSize = true
            recordCurrentFontSizeLineage(targetLineage)
            _ = fontSizeLineageSnapshot()
            return true
        }

        let alreadyFollowsTarget =
            followsConfiguredFontSize
            && (
                lastKnownFontSizeLineage == nil
                    || lastKnownFontSizeLineage == targetLineage
            )
        followsConfiguredFontSize = true
        if !alreadyFollowsTarget {
            recordCurrentFontSizeLineage(targetLineage)
        }
        return !alreadyFollowsTarget
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
        template.fontSizeChangeToken = lastAppliedFontSizeChangeToken
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
