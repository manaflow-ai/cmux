internal import CmuxTerminalCore
import Foundation
internal import GhosttyKit

/// Opaque token pairing a synchronous configuration reload with its active
/// mobile viewport font lease.
nonisolated public struct MobileViewportFontFitReloadLease {
    let columns: Int
    let rows: Int
    let surrendered: Bool
    let userAdjustedBaseFontPointSize: Float?
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
    func restoreMobileViewportFitFontIfNeeded() -> Bool {
        let plan = mobileViewportFontFitState.restorePlan(
            configuredFontPointSize: configuredMobileViewportFontPointSize()
        )
        guard plan != .none else {
            mobileViewportFontFitState.clear()
            return false
        }

        let restored: Bool
        switch plan {
        case .none:
            restored = false
        case .resetToConfigured:
            restored = performBindingAction("reset_font_size")
        case .resetThenSet(let baseFontPointSize):
            restored = performBindingAction("reset_font_size") &&
                applyMobileViewportFontPointSize(baseFontPointSize)
        }
        guard restored else { return false }
        mobileViewportFontFitState.clear()
        return restored
    }

    /// Synchronously yields automatic font ownership before a configuration reload.
    @MainActor
    public func prepareMobileViewportFontFitForConfigurationReload(
        reason: String
    ) -> MobileViewportFontFitReloadLease? {
        pendingMobileViewportFontFitReloadLease = nil
        guard !manualIO,
              let limit = mobileViewportCellLimit,
              let surface = liveSurfaceForGhosttyAccess(reason: reason) else {
            return nil
        }

        mobileViewportFontFitState.reconcilePendingLiveFontProbe(
            configuredFontPointSize: configuredMobileViewportFontPointSize()
        ) {
            GhosttySurfaceRuntimeProbe.currentCoreSurfaceFontSizePoints(surface)
        }

        let hadAutomaticFit = mobileViewportFontFitState.fittedFontPointSize != nil
        let userAdjustedBaseFontPointSize = mobileViewportFontFitState.baseWasUserAdjusted == true
            ? mobileViewportFontFitState.baseFontPointSize
            : nil
        let surrendered = !hadAutomaticFit || restoreMobileViewportFitFontIfNeeded()
        let lease = MobileViewportFontFitReloadLease(
            columns: limit.columns,
            rows: limit.rows,
            surrendered: surrendered,
            userAdjustedBaseFontPointSize: userAdjustedBaseFontPointSize
        )
        pendingMobileViewportFontFitReloadLease = lease
        return lease
    }

    /// Completes a pending reload from Ghostty's resolved surface config signal.
    @MainActor
    public func completeMobileViewportFontFitConfigurationReload(
        configuredFontPointSize: Float?,
        reason: String
    ) {
        recordMobileViewportConfiguredFontPointSize(configuredFontPointSize)
        guard let lease = pendingMobileViewportFontFitReloadLease else { return }
        pendingMobileViewportFontFitReloadLease = nil
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
