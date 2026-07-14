internal import CmuxTerminalCore
import Foundation
internal import GhosttyKit

/// Opaque token pairing a synchronous configuration reload with its active
/// mobile viewport font lease.
nonisolated public struct MobileViewportFontFitReloadLease {
    let generation: UInt64
    let columns: Int
    let rows: Int
    let surrendered: Bool
    let userAdjustedBaseFontPointSize: Float?
}

nonisolated struct MobileViewportFontFitReloadLeaseCompletion {
    let lease: MobileViewportFontFitReloadLease?
}

/// Serializes configuration reload preparation and completion. The generation
/// belongs to the reload even when no mobile font lease is active, allowing a
/// delayed callback to record configuration only for its own preparation.
nonisolated struct MobileViewportFontFitReloadLeaseState {
    private var nextGeneration: UInt64 = 0
    private(set) var pendingGeneration: UInt64?
    private var pendingLease: MobileViewportFontFitReloadLease?

    mutating func beginPreparation() -> UInt64 {
        nextGeneration &+= 1
        pendingGeneration = nextGeneration
        pendingLease = nil
        return nextGeneration
    }

    mutating func prepare(
        columns: Int,
        rows: Int,
        surrendered: Bool,
        userAdjustedBaseFontPointSize: Float?
    ) -> MobileViewportFontFitReloadLease {
        let generation = beginPreparation()
        return install(
            generation: generation,
            columns: columns,
            rows: rows,
            surrendered: surrendered,
            userAdjustedBaseFontPointSize: userAdjustedBaseFontPointSize
        )
    }

    mutating func install(
        generation: UInt64,
        columns: Int,
        rows: Int,
        surrendered: Bool,
        userAdjustedBaseFontPointSize: Float?
    ) -> MobileViewportFontFitReloadLease {
        precondition(pendingGeneration == generation)
        let lease = MobileViewportFontFitReloadLease(
            generation: generation,
            columns: columns,
            rows: rows,
            surrendered: surrendered,
            userAdjustedBaseFontPointSize: userAdjustedBaseFontPointSize
        )
        pendingLease = lease
        return lease
    }

    mutating func consumeReload(
        generation: UInt64
    ) -> MobileViewportFontFitReloadLeaseCompletion? {
        guard pendingGeneration == generation else { return nil }
        let completion = MobileViewportFontFitReloadLeaseCompletion(lease: pendingLease)
        pendingGeneration = nil
        pendingLease = nil
        return completion
    }

    mutating func consume(generation: UInt64) -> MobileViewportFontFitReloadLease? {
        consumeReload(generation: generation)?.lease
    }

    mutating func discardLease() {
        pendingLease = nil
    }
}

nonisolated struct MobileViewportResetFontPointSize {
    let surfaceConfigFontPointSize: Float?
    let runtimeConfigFontPointSize: Float?
    let fallbackBaseFontPointSize: Float
    let magnificationPercent: Int

    func resolve() -> Float {
        if let surfaceConfigFontPointSize,
           surfaceConfigFontPointSize.isFinite,
           surfaceConfigFontPointSize > 0 {
            return surfaceConfigFontPointSize
        }
        if let runtimeConfigFontPointSize,
           runtimeConfigFontPointSize.isFinite,
           runtimeConfigFontPointSize > 0 {
            return runtimeConfigFontPointSize
        }
        return CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: fallbackBaseFontPointSize,
            percent: magnificationPercent
        )
    }
}

extension TerminalSurface {
    @MainActor
    func configuredMobileViewportFontPointSize() -> Float {
        MobileViewportConfiguredFontPointSizeResolver(
            surfaceConfigFontPointSize: mobileViewportConfiguredFontPointSize,
            runtimeConfigFontPointSize: { self.runtimeConfigFontPointSize() },
            fallbackBaseFontPointSize: { Float(GhosttyConfig().fontSize) },
            magnificationPercent: globalFontMagnificationPercent()
        ).resolve()
    }

    /// Records the finalized configuration applied to this specific surface.
    @MainActor
    public func recordMobileViewportConfiguredFontPointSize(_ points: Float?) {
        guard let points, points.isFinite, points > 0 else {
            mobileViewportConfiguredFontPointSize = nil
            return
        }
        mobileViewportConfiguredFontPointSize = points
    }

    @MainActor
    private func runtimeConfigFontPointSize() -> Float? {
        guard let config = engine.runtimeConfig else { return nil }
        var fontSize: Float32 = 0
        let key = "font-size"
        guard ghostty_config_get(
            config,
            &fontSize,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        ), fontSize.isFinite, fontSize > 0 else { return nil }
        return fontSize
    }

    @discardableResult
    @MainActor
    func restoreMobileViewportFitFontIfNeeded() -> MobileViewportFontRestoreOutcome {
        let plan = mobileViewportFontFitState.restorePlan(
            configuredFontPointSize: configuredMobileViewportFontPointSize()
        )
        let outcome = plan.restore(
            reset: { performBindingAction("reset_font_size") },
            set: { applyMobileViewportFontPointSize($0) }
        )
        mobileViewportFontFitState.reconcileRestoreOutcome(outcome)
        return outcome
    }

    /// Synchronously yields automatic font ownership before a configuration reload.
    @MainActor
    public func prepareMobileViewportFontFitForConfigurationReload(
        reason: String
    ) -> MobileViewportFontFitReloadLease? {
        let reloadGeneration = mobileViewportFontFitReloadLeaseState.beginPreparation()
        guard !manualIO,
              let limit = mobileViewportCellLimit,
              let surface = liveSurfaceForGhosttyAccess(reason: reason) else {
            return nil
        }

        mobileViewportFontFitState.reconcilePendingLiveFontProbe(
            configuredFontPointSize: configuredMobileViewportFontPointSize()
        ) {
            MobileViewportLiveFontProbe(surface: surface).read()
        }

        let hadAutomaticFit = mobileViewportFontFitState.fittedFontPointSize != nil
        let userAdjustedBaseFontPointSize = mobileViewportFontFitState.baseWasUserAdjusted == true
            ? mobileViewportFontFitState.baseFontPointSize
            : nil
        let surrendered = !hadAutomaticFit ||
            restoreMobileViewportFitFontIfNeeded().surrenderedAutomaticFit
        return mobileViewportFontFitReloadLeaseState.install(
            generation: reloadGeneration,
            columns: limit.columns,
            rows: limit.rows,
            surrendered: surrendered,
            userAdjustedBaseFontPointSize: userAdjustedBaseFontPointSize
        )
    }

    @MainActor
    public var pendingMobileViewportFontFitReloadGeneration: UInt64? {
        mobileViewportFontFitReloadLeaseState.pendingGeneration
    }

    /// Completes a pending reload from Ghostty's resolved surface config signal.
    @MainActor
    public func completeMobileViewportFontFitConfigurationReload(
        configuredFontPointSize: Float?,
        reloadGeneration: UInt64,
        reason: String
    ) {
        guard let completion = mobileViewportFontFitReloadLeaseState.consumeReload(
            generation: reloadGeneration
        ) else { return }
        recordMobileViewportConfiguredFontPointSize(configuredFontPointSize)
        guard let lease = completion.lease else { return }
        guard liveSurfaceForGhosttyAccess(reason: "\(reason).refit") != nil else {
            mobileViewportFontFitState.clear()
            return
        }
        let configuredFontOverride = lease.surrendered
            ? configuredMobileViewportFontPointSize()
            : nil
        if lease.surrendered {
            mobileViewportFontFitState.clear()
            let liveFont = configuredFontOverride ?? configuredMobileViewportFontPointSize()
            mobileViewportFontFitState.begin(
                baseFontPointSize: liveFont,
                configuredFontPointSize: liveFont,
                preservedUserAdjustedBaseFontPointSize: lease.userAdjustedBaseFontPointSize
            )
            // The finalized config is authoritative until Ghostty confirms its
            // asynchronous renderer update through the cell-metrics callback.
            mobileViewportFontFitState.suppressLiveFontProbeUntilMetricsChange()
        }
        _ = applyMobileViewportLimit(
            columns: lease.columns,
            rows: lease.rows,
            reason: "\(reason).refit",
            configuredFontPointSizeOverride: configuredFontOverride
        )
    }

    /// Yields automatic font ownership around one synchronous surface reload.
    @MainActor
    public func withMobileViewportFontFitSurrenderedForConfigurationReload(
        reason: String,
        reload: () -> Void
    ) {
        _ = prepareMobileViewportFontFitForConfigurationReload(reason: reason)
        reload()
    }

    @MainActor
    @discardableResult
    func applyMobileViewportFontPointSize(_ points: Float) -> Bool {
        let action = String(format: "set_font_size:%.3f", points)
        return performBindingAction(action)
    }
}
