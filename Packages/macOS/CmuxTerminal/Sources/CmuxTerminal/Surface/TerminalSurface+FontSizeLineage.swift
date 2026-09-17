public import CmuxTerminalCore
public import Foundation
internal import GhosttyKit

func ghosttySetFontSizeBindingAction(_ points: Float) -> String {
    "set_font_size:" + String(points)
}

/// Keeps projected request provenance live until its owner retires.
@MainActor
public func activateTerminalFontSizeChangeReconciliationToken(
    _ token: UUID
) {
    TerminalSurface.activeTransferReconciliationTokens.insert(token)
}

/// Invalidates retired provenance without scanning live terminal surfaces.
@MainActor
public func retireTerminalFontSizeChangeReconciliationToken(
    _ token: UUID
) {
    TerminalSurface
        .debugLastTransferTokenRetirementSurfaceVisitCount = 0
    if TerminalSurface.activeTransferReconciliationTokens
        .remove(token) != nil {
        TerminalSurface
            .transferReconciliationRetirementGeneration &+= 1
    }
}

extension TerminalSurface {
    @MainActor
    fileprivate static var activeTransferReconciliationTokens: Set<UUID> = []

    @MainActor
    fileprivate static var transferReconciliationRetirementGeneration: UInt64 = 0

    private static let transferReconciliationPruneInterval: UInt64 = 32

    @MainActor
    static var debugLastTransferTokenRetirementSurfaceVisitCount = 0

    @MainActor
    var debugTransferReconciliationTokenStorageCount: Int {
        transferReconciledFontSizeChangeTokens.count
    }

    /// Marks that a higher-level batched font-size request already contributed
    /// to this surface's lineage. New descendants can carry the same request
    /// provenance without inferring ownership from a colliding point value.
    @MainActor
    public func markFontSizeChangeApplied(token: UUID) {
        lastAppliedFontSizeChangeToken = token
    }

    /// Records transient request provenance while this live panel transfers
    /// between containers. The owning coordinator retires the token when its
    /// coalesced event batch finishes, so this set is bounded by in-flight work.
    @MainActor
    public func markFontSizeChangeReconciledForTransfer(token: UUID) {
        pruneRetiredFontSizeTransferTokens(force: false)
        activateTerminalFontSizeChangeReconciliationToken(token)
        transferReconciledFontSizeChangeTokens.insert(token)
    }

    /// Removes transient transfer provenance from this surface after its
    /// coordinating request retires.
    @MainActor
    public func clearFontSizeChangeReconciledForTransfer(token: UUID) {
        transferReconciledFontSizeChangeTokens.remove(token)
    }

    /// Tokens whose changes are already represented by this surface's lineage
    /// and must be copied when it seeds a descendant.
    @MainActor
    public func fontSizeChangeTokensForInheritance() -> Set<UUID> {
        pruneRetiredFontSizeTransferTokens(force: true)
        return transferReconciledFontSizeChangeTokens
    }

    /// Returns whether this surface's lineage already includes `token`.
    @MainActor
    public func hasAppliedFontSizeChange(token: UUID) -> Bool {
        if lastAppliedFontSizeChangeToken == token {
            return true
        }
        guard Self.activeTransferReconciliationTokens.contains(token) else {
            transferReconciledFontSizeChangeTokens.remove(token)
            return false
        }
        return transferReconciledFontSizeChangeTokens.contains(token)
    }

    @MainActor
    private func pruneRetiredFontSizeTransferTokens(force: Bool) {
        let retirementGeneration =
            Self.transferReconciliationRetirementGeneration
        let retirementCount =
            retirementGeneration
            &- lastPrunedFontSizeTransferRetirementGeneration
        guard force
                || retirementCount
                    >= Self.transferReconciliationPruneInterval else {
            return
        }
        transferReconciledFontSizeChangeTokens.formIntersection(
            Self.activeTransferReconciliationTokens
        )
        lastPrunedFontSizeTransferRetirementGeneration =
            retirementGeneration
    }

    /// Adjusts this terminal's runtime font size and records an explicit override.
    ///
    /// Live surfaces delegate to Ghostty's native font-size action. Suspended or
    /// deferred surfaces update their durable lineage directly so the change is
    /// applied when their runtime is created again.
    /// Input attribution belongs to the initiating UI boundary because one
    /// workspace action can invoke this mutation for many background surfaces.
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
        return adjustFontSize(
            applying: TerminalFontSizeDeltaTransform(
                orderedRuntimePointDeltas: orderedRuntimePointDeltas
            ),
            fallbackRuntimePoints: fallbackRuntimePoints
        )
    }

    /// Applies a constant-size ordered clamp transform while rebuilding a live
    /// font at most once.
    @MainActor
    @discardableResult
    public func adjustFontSize(
        applying transform: TerminalFontSizeDeltaTransform,
        fallbackRuntimePoints: Float32? = nil
    ) -> Bool {
        adjustFontSizeOutcome(
            applying: transform,
            fallbackRuntimePoints: fallbackRuntimePoints
        ).didChange
    }

    /// Applies a clamp transform while distinguishing a satisfied bound from
    /// an action failure. Callers that record request provenance must use this
    /// result instead of the legacy changed/not-changed Boolean.
    @MainActor
    public func adjustFontSizeOutcome(
        applying transform: TerminalFontSizeDeltaTransform,
        fallbackRuntimePoints: Float32? = nil,
        magnificationPercent: Int? = nil
    ) -> TerminalFontSizeMutationOutcome {
        guard !transform.isIdentity else { return .alreadySatisfied }

        let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "fontSize.adjust")
        let percent =
            magnificationPercent
            ?? globalFontMagnificationPercent()
        if runtimeSurface != nil,
           let mobileFitResult = adjustDurableMobileViewportFontSize(
                applying: transform,
                magnificationPercent: percent
           ) {
            return mobileFitResult
        }
        guard let baseline = fontSizeAdjustmentBaseline(
            fallbackRuntimePoints: fallbackRuntimePoints,
            magnificationPercent: percent
        ) else {
            return .failed
        }

        let policy = TerminalFontSizePolicy()
        let boundedCurrentRuntimePoints = policy.clampedRuntimePoints(
            baseline.runtimePoints
        )
        let adjustedRuntimePoints = transform.applying(
            to: boundedCurrentRuntimePoints
        )
        let netRuntimePointDelta = adjustedRuntimePoints - boundedCurrentRuntimePoints
        guard netRuntimePointDelta != 0 else {
            guard !baseline.lineage.isExplicitOverride else {
                return .alreadySatisfied
            }
            if runtimeSurface != nil {
                guard performInternalBindingAction(
                    ghosttySetFontSizeBindingAction(
                        adjustedRuntimePoints
                    )
                ) else {
                    return .failed
                }
                followsConfiguredFontSize = false
                _ = fontSizeLineageSnapshot(
                    magnificationPercent: percent
                )
                return .applied
            }
            claimExplicitFontSizeOwnership(
                atRuntimePoints: adjustedRuntimePoints,
                previousLineage: baseline.lineage,
                magnificationPercent: percent
            )
            return .applied
        }

        if runtimeSurface != nil {
            let verb = netRuntimePointDelta > 0
                ? "increase_font_size"
                : "decrease_font_size"
            let action = "\(verb):\(abs(netRuntimePointDelta))"
            guard performInternalBindingAction(action) else {
                return .failed
            }
            followsConfiguredFontSize = false
            _ = fontSizeLineageSnapshot(
                magnificationPercent: percent
            )
            return .applied
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
        return .applied
    }

    @MainActor
    private func claimExplicitFontSizeOwnership(
        atRuntimePoints runtimePoints: Float32,
        previousLineage: TerminalFontSizeLineage,
        magnificationPercent: Int
    ) {
        if var reloadState = pendingFontSizeConfigurationReloadState {
            reloadState.recordRelativeFontInput(
                previousRuntimePoints: runtimePoints,
                currentRuntimePoints: runtimePoints,
                previousIsAdjusted:
                    previousLineage.isExplicitOverride,
                currentIsAdjusted: true
            )
            pendingFontSizeConfigurationReloadState =
                reloadState
        }
        followsConfiguredFontSize = false
        recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                    fromRuntimePoints: runtimePoints,
                    percent: magnificationPercent
                ),
                isExplicitOverride: true
            )
        )
    }

    /// Returns the same starting lineage used by a relative font mutation.
    ///
    /// Active workspace inheritance uses this prediction before a bounded
    /// drain reaches the source panel. A hibernated follower therefore starts
    /// from current configuration, while an explicit override and a
    /// never-realized inherited value retain their own base.
    @MainActor
    public func fontSizeLineageForAdjustment(
        fallbackRuntimePoints: Float32? = nil,
        magnificationPercent: Int? = nil
    ) -> TerminalFontSizeLineage? {
        if let pendingFontSizeConfigurationReloadState {
            return pendingFontSizeConfigurationReloadState
                .inheritanceLineage
        }
        return fontSizeAdjustmentBaseline(
            fallbackRuntimePoints: fallbackRuntimePoints,
            magnificationPercent:
                magnificationPercent
                ?? globalFontMagnificationPercent()
        )?.lineage
    }

    @MainActor
    private func fontSizeAdjustmentBaseline(
        fallbackRuntimePoints: Float32?,
        magnificationPercent percent: Int
    ) -> (
        runtimePoints: Float32,
        lineage: TerminalFontSizeLineage
    )? {
        rebaseStaleConfigurationFollowingLineageIfNeeded(
            magnificationPercent: percent
        )
        if let runtimeSurface = liveSurfaceForGhosttyAccess(
            reason: "fontSize.adjustBaseline"
        ),
        let observedRuntimePoints =
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ),
        let observedLineage = recordObservedFontSizeLineage(
            runtimePoints: observedRuntimePoints,
            isExplicitOverride:
                ghostty_surface_font_size_adjusted(runtimeSurface),
            globalFontMagnificationPercent: percent
        ) {
            return (observedRuntimePoints, observedLineage)
        }

        if !followsConfiguredFontSize,
           let lineage = lastKnownFontSizeLineage,
           lineage.isExplicitOverride || runtimeSurfaceGeneration == 0 {
            return (
                CmuxSurfaceConfigTemplate.runtimeFontSize(
                    fromBasePoints: lineage.basePoints,
                    percent: percent
                ),
                lineage
            )
        }

        guard let fallbackRuntimePoints,
              fallbackRuntimePoints.isFinite,
              fallbackRuntimePoints > 0 else {
            return nil
        }
        let boundedRuntimePoints =
            TerminalFontSizePolicy().clampedRuntimePoints(
                fallbackRuntimePoints
            )
        return (
            boundedRuntimePoints,
            TerminalFontSizeLineage(
                basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                    fromRuntimePoints: boundedRuntimePoints,
                    percent: percent
                ),
                isExplicitOverride: false
            )
        )
    }

    /// Resets this terminal to the current configured runtime font size.
    ///
    /// Live surfaces use Ghostty's font-only reset action. Ghostty refreshes
    /// that action's baseline during normal config reloads, so reset does not
    /// need a full surface-config update. Suspended or deferred surfaces clear
    /// their durable override so future runtimes follow terminal configuration.
    /// Input attribution remains the responsibility of the initiating UI.
    ///
    /// - Parameter configuredRuntimePoints: Current configured size after
    ///   global magnification.
    /// - Returns: Whether the live reset ran or durable lineage was updated.
    @MainActor
    @discardableResult
    public func resetFontSize(toConfiguredRuntimePoints configuredRuntimePoints: Float32) -> Bool {
        resetFontSizeOutcome(
            toConfiguredRuntimePoints: configuredRuntimePoints
        ).didChange
    }

    /// Resets to the configured size while preserving the distinction between
    /// an already-satisfied surface and a failed native action.
    @MainActor
    public func resetFontSizeOutcome(
        toConfiguredRuntimePoints configuredRuntimePoints: Float32,
        magnificationPercent: Int? = nil
    ) -> TerminalFontSizeMutationOutcome {
        guard configuredRuntimePoints.isFinite,
              configuredRuntimePoints > 0 else {
            return .failed
        }

        let targetRuntimePoints = TerminalFontSizePolicy().clampedRuntimePoints(
            configuredRuntimePoints
        )
        let magnificationPercent =
            magnificationPercent
            ?? globalFontMagnificationPercent()
        let targetLineage = TerminalFontSizeLineage(
            basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: targetRuntimePoints,
                percent: magnificationPercent
            ),
            isExplicitOverride: false
        )

        if let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "fontSize.reset") {
            if let mobileFitResult = resetDurableMobileViewportFontSize(
                to: targetRuntimePoints,
                lineage: targetLineage
            ) {
                return mobileFitResult
            }
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
                    ? .applied
                    : .alreadySatisfied
            }

            guard performInternalBindingAction("reset_font_size") else {
                return .failed
            }
            followsConfiguredFontSize = true
            recordCurrentFontSizeLineage(targetLineage)
            _ = fontSizeLineageSnapshot(
                magnificationPercent: magnificationPercent
            )
            return .applied
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
        return alreadyFollowsTarget
            ? .alreadySatisfied
            : .applied
    }

    @MainActor
    private func adjustDurableMobileViewportFontSize(
        applying transform: TerminalFontSizeDeltaTransform,
        magnificationPercent: Int
    ) -> TerminalFontSizeMutationOutcome? {
        guard var nextFitState = mobileViewportFontFitState else {
            return nil
        }
        let policy = TerminalFontSizePolicy()
        let currentRuntimePoints = policy.clampedRuntimePoints(
            nextFitState.baseRuntimePointSize
        )
        let targetRuntimePoints = transform.applying(
            to: currentRuntimePoints
        )
        guard targetRuntimePoints != currentRuntimePoints else {
            let previousLineage =
                lastKnownFontSizeLineage
                ?? TerminalFontSizeLineage(
                    basePoints:
                        CmuxSurfaceConfigTemplate.baseFontSize(
                            fromRuntimePoints:
                                currentRuntimePoints,
                            percent:
                                magnificationPercent
                        ),
                    isExplicitOverride: false
                )
            guard !previousLineage.isExplicitOverride else {
                return .alreadySatisfied
            }
            claimExplicitFontSizeOwnership(
                atRuntimePoints: targetRuntimePoints,
                previousLineage: previousLineage,
                magnificationPercent: magnificationPercent
            )
            return .applied
        }

        let previousFittedRuntimePoints =
            nextFitState.fittedRuntimePointSize
        nextFitState.updateDurableBase(to: targetRuntimePoints)
        if nextFitState.fittedRuntimePointSize
                != previousFittedRuntimePoints,
           !performMobileViewportFontPointSizeAction(
                nextFitState.fittedRuntimePointSize
           ) {
            return .failed
        }

        mobileViewportFontFitState = nextFitState
        followsConfiguredFontSize = false
        recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints: CmuxSurfaceConfigTemplate.baseFontSize(
                    fromRuntimePoints: targetRuntimePoints,
                    percent: magnificationPercent
                ),
                isExplicitOverride: true
            )
        )
        return .applied
    }

    @MainActor
    private func resetDurableMobileViewportFontSize(
        to targetRuntimePoints: Float32,
        lineage targetLineage: TerminalFontSizeLineage
    ) -> TerminalFontSizeMutationOutcome? {
        guard var nextFitState = mobileViewportFontFitState else {
            return nil
        }
        let previousFitState = nextFitState
        nextFitState.updateDurableBase(to: targetRuntimePoints)
        let alreadyFollowsTarget =
            followsConfiguredFontSize
            && (
                lastKnownFontSizeLineage == nil
                    || lastKnownFontSizeLineage == targetLineage
            )
        guard nextFitState != previousFitState
                || !alreadyFollowsTarget else {
            return .alreadySatisfied
        }

        if nextFitState.fittedRuntimePointSize
                != previousFitState.fittedRuntimePointSize,
           !performMobileViewportFontPointSizeAction(
                nextFitState.fittedRuntimePointSize
           ) {
            return .failed
        }

        mobileViewportFontFitState = nextFitState
        followsConfiguredFontSize = true
        if !alreadyFollowsTarget {
            recordCurrentFontSizeLineage(targetLineage)
        }
        return .applied
    }

    /// Captures durable font ownership against the config that is still live.
    ///
    /// This must run before `ghostty_app_update_config`. An adjusted Ghostty
    /// surface preserves its old runtime point value through that call, so
    /// interpreting it afterward with a new magnification would corrupt the
    /// unscaled base.
    @MainActor
    public func captureFontSizeConfigurationReloadState(
        magnificationPercent: Int,
        targetConfiguredRuntimePoints: Float32? = nil,
        targetMagnificationPercent: Int? = nil
    ) -> TerminalFontSizeConfigurationReloadState {
        precondition(
            pendingFontSizeConfigurationReloadState == nil,
            "Terminal font configuration reloads must remain serialized"
        )
        let lineage = fontSizeLineageSnapshot(
            magnificationPercent: magnificationPercent
        )
        var state = TerminalFontSizeConfigurationReloadState(
            transactionId: UUID(),
            surfaceId: id,
            lineage: lineage,
            inheritanceLineage: lineage,
            followsConfiguredFontSize:
                followsConfiguredFontSize,
            targetConfiguredRuntimePoints:
                targetConfiguredRuntimePoints,
            targetMagnificationPercent:
                targetMagnificationPercent
        )
        state.inheritanceLineage =
            state.resolvedTargetLineage()
        pendingFontSizeConfigurationReloadState = state
        return state
    }

    /// Reconciles native runtime points with a newly applied app config.
    ///
    /// Explicit terminals retain their unscaled base and receive the new
    /// magnification. Config followers adopt the new configured size. A
    /// temporary mobile fit keeps its fitted live size while its durable base
    /// is rebased to either result.
    @MainActor
    public func reconcileFontSizeAfterConfigurationReload(
        from state: TerminalFontSizeConfigurationReloadState,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int
    ) -> TerminalFontSizeMutationOutcome {
        guard state.surfaceId == id,
              let activeState =
                pendingFontSizeConfigurationReloadState,
              activeState.transactionId == state.transactionId,
              configuredRuntimePoints.isFinite,
              configuredRuntimePoints > 0 else {
            return .failed
        }

        let resolvedTarget = activeState.resolvedTarget(
            configuredRuntimePoints: configuredRuntimePoints,
            magnificationPercent: magnificationPercent
        )
        let durableRuntimePoints =
            resolvedTarget.durableRuntimePoints
        let retainsExplicitBase =
            resolvedTarget.retainsExplicitBase
        let targetLineage = resolvedTarget.lineage

        let desiredLiveRuntimePoints: Float32
        let retainsMobileFit: Bool
        let nextFitState: MobileViewportFontFitState?
        if var fitState = mobileViewportFontFitState {
            fitState.updateDurableBase(to: durableRuntimePoints)
            nextFitState = fitState
            desiredLiveRuntimePoints = fitState.fittedRuntimePointSize
            retainsMobileFit = true
        } else {
            nextFitState = nil
            desiredLiveRuntimePoints = durableRuntimePoints
            retainsMobileFit = false
        }

        func commitDurableState() {
            mobileViewportFontFitState = nextFitState
            followsConfiguredFontSize = !retainsExplicitBase
            recordCurrentFontSizeLineage(targetLineage)
            if pendingFontSizeConfigurationReloadState?
                    .transactionId == state.transactionId {
                pendingFontSizeConfigurationReloadState = nil
            }
        }

        guard let runtimeSurface = liveSurfaceForGhosttyAccess(
            reason: "fontSize.configReload"
        ) else {
            commitDurableState()
            return .alreadySatisfied
        }
        let observedRuntimePoints =
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            )
        let nativeIsAdjusted =
            ghostty_surface_font_size_adjusted(runtimeSurface)
        let nativeMatchesTarget = observedRuntimePoints.map {
            abs($0 - desiredLiveRuntimePoints) <= 0.000_1
        } ?? false

        if retainsExplicitBase || retainsMobileFit {
            guard !nativeMatchesTarget || !nativeIsAdjusted else {
                commitDurableState()
                return .alreadySatisfied
            }
            guard performMobileViewportFontPointSizeAction(
                desiredLiveRuntimePoints
            ) else {
                return .failed
            }
            commitDurableState()
            return .applied
        }

        guard !nativeMatchesTarget || nativeIsAdjusted else {
            commitDurableState()
            return .alreadySatisfied
        }
        guard performInternalBindingAction("reset_font_size") else {
            return .failed
        }
        commitDurableState()
        return .applied
    }

    /// Finishes a reconciliation that exhausted its native retries.
    ///
    /// The desired state was never committed. A mobile viewport fit keeps the
    /// captured durable target separate from its temporary live points.
    /// Otherwise, an observed post-config value becomes the fallback lineage
    /// so snapshots cannot reinterpret old points with new magnification.
    @MainActor
    public func abandonFontSizeConfigurationReloadReconciliation(
        from state: TerminalFontSizeConfigurationReloadState,
        magnificationPercent: Int
    ) {
        guard let activeState =
                pendingFontSizeConfigurationReloadState,
              activeState.transactionId
                == state.transactionId else {
            return
        }
        if let runtimeSurface = liveSurfaceForGhosttyAccess(
            reason: "fontSize.configReload.abandon"
        ),
        let runtimePoints =
            GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(
                runtimeSurface
            ) {
            let policy = TerminalFontSizePolicy()
            let runtimePoints = policy.clampedRuntimePoints(
                runtimePoints
            )
            let isExplicitOverride =
                ghostty_surface_font_size_adjusted(runtimeSurface)
            if var fitState = mobileViewportFontFitState,
               let targetLineage =
                    activeState.resolvedTargetLineage() {
                let durableRuntimePoints =
                    policy.clampedRuntimePoints(
                        CmuxSurfaceConfigTemplate
                            .runtimeFontSize(
                                fromBasePoints:
                                    targetLineage.basePoints,
                                percent:
                                    magnificationPercent
                            )
                    )
                fitState.updateDurableBase(
                    to: durableRuntimePoints
                )
                mobileViewportFontFitState = fitState
                followsConfiguredFontSize =
                    !targetLineage.isExplicitOverride
                recordCurrentFontSizeLineage(targetLineage)
            } else {
                followsConfiguredFontSize =
                    !isExplicitOverride
                recordCurrentFontSizeLineage(
                    TerminalFontSizeLineage(
                        basePoints:
                            CmuxSurfaceConfigTemplate
                                .baseFontSize(
                                    fromRuntimePoints:
                                        runtimePoints,
                                    percent:
                                        magnificationPercent
                                ),
                        isExplicitOverride:
                            isExplicitOverride
                    )
                )
            }
        }
        pendingFontSizeConfigurationReloadState = nil
    }

    /// Captures the current font size and its surface-local ownership state.
    ///
    /// Live Ghostty state is authoritative. When the runtime is unavailable,
    /// the last captured lineage survives hibernation and session restoration.
    ///
    /// - Returns: Current font-size lineage, or nil before a size is known.
    @MainActor
    public func fontSizeLineageSnapshot(
        magnificationPercent: Int? = nil
    ) -> TerminalFontSizeLineage? {
        if let pendingFontSizeConfigurationReloadState {
            return pendingFontSizeConfigurationReloadState
                .inheritanceLineage
        }
        rebaseStaleConfigurationFollowingLineageIfNeeded(
            magnificationPercent: magnificationPercent
        )
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
            globalFontMagnificationPercent:
                magnificationPercent
                ?? globalFontMagnificationPercent()
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
        if let pendingFontSizeConfigurationReloadState {
            return pendingFontSizeConfigurationReloadState
                .inheritanceLineage
        }
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
        if isExplicitOverride,
           let lastKnownFontSizeLineage,
           lastKnownFontSizeLineage.isExplicitOverride {
            let projectedRuntimePoints =
                TerminalFontSizePolicy().clampedRuntimePoints(
                    CmuxSurfaceConfigTemplate.runtimeFontSize(
                        fromBasePoints:
                            lastKnownFontSizeLineage.basePoints,
                        percent: globalFontMagnificationPercent
                    )
                )
            if abs(runtimePoints - projectedRuntimePoints) <= 0.000_1 {
                followsConfiguredFontSize = false
                return lastKnownFontSizeLineage
            }
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
        fontSizeLineageConfigurationGeneration =
            engine.terminalFontConfigurationGeneration
        if lineage.isExplicitOverride {
            followsConfiguredFontSize = false
        }
        guard lastKnownFontSizeLineage != lineage else { return }
        lastKnownFontSizeLineage = lineage
        onFontSizeLineageChanged?(lineage)
    }

    /// Makes a runtime deferred across config replacement consume the newly
    /// applied configured font. Explicit overrides retain their unscaled base;
    /// a non-explicit inheritance seed is stale once the replacement config is
    /// live and must not pin the old configured size.
    @MainActor
    func prepareFontSizeForDeferredConfigurationRuntimeCreation() {
        guard lastKnownFontSizeLineage?
                .isExplicitOverride == false else {
            return
        }
        followsConfiguredFontSize = true
    }

    /// Resolves the Swift-owned template used to create this surface's runtime.
    ///
    /// Initial non-explicit lineage seeds the first native runtime. After a
    /// native lifetime, non-explicit lineage remains available to descendants
    /// but must not seed this surface again because Cmd+0 and ordinary unzoomed
    /// terminals follow the then-current terminal config.
    @MainActor
    func runtimeCreationConfigTemplate() -> CmuxSurfaceConfigTemplate {
        rebaseStaleConfigurationFollowingLineageIfNeeded()
        var template = configTemplate ?? CmuxSurfaceConfigTemplate()
        template.fontSizeChangeToken = lastAppliedFontSizeChangeToken
        template.fontSizeChangeTokens =
            fontSizeChangeTokensForInheritance()
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

    /// Rebases a config-following seed that missed an incremental reload walk.
    ///
    /// The engine generation advances when the replacement config becomes
    /// active. A dormant surface created after the walk's fixed cutoff keeps
    /// its old seed until this boundary, then adopts the applied configured
    /// value before it can start a runtime or seed a descendant.
    @MainActor
    private func rebaseStaleConfigurationFollowingLineageIfNeeded(
        magnificationPercent: Int? = nil
    ) {
        guard pendingFontSizeConfigurationReloadState == nil,
              lastKnownFontSizeLineage?
                .isExplicitOverride == false else {
            return
        }
        let appliedGeneration =
            engine.terminalFontConfigurationGeneration
        guard fontSizeLineageConfigurationGeneration
                != appliedGeneration else {
            return
        }
        let percent =
            magnificationPercent
            ?? globalFontMagnificationPercent()
        let configuredRuntimePoints =
            TerminalFontSizePolicy().clampedRuntimePoints(
                engine.terminalFontConfigurationRuntimePoints
            )
        followsConfiguredFontSize = true
        recordCurrentFontSizeLineage(
            TerminalFontSizeLineage(
                basePoints:
                    CmuxSurfaceConfigTemplate.baseFontSize(
                        fromRuntimePoints:
                            configuredRuntimePoints,
                        percent: percent
                    ),
                isExplicitOverride: false
            )
        )
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
