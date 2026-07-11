internal import CmuxTerminalCore
import Foundation

/// Opaque token pairing a synchronous configuration reload with its active
/// mobile viewport font lease.
nonisolated public struct MobileViewportFontFitReloadLease {
    let columns: Int
    let rows: Int
    let surrendered: Bool
    let userAdjustedBaseFontPointSize: Float?
}

nonisolated enum MobileViewportConfiguredFontPointSize {
    static func resolve(
        templateBaseFontPointSize: Float?,
        runtimeConfigFontPointSize _: Float?,
        fallbackBaseFontPointSize: Float,
        magnificationPercent: Int
    ) -> Float {
        let baseFont = templateBaseFontPointSize ?? fallbackBaseFontPointSize
        return CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseFont > 0 ? baseFont : fallbackBaseFontPointSize,
            percent: magnificationPercent
        )
    }
}

extension TerminalSurface {
    @MainActor
    func configuredMobileViewportFontPointSize() -> Float {
        MobileViewportConfiguredFontPointSize.resolve(
            templateBaseFontPointSize: configTemplate?.fontSize,
            runtimeConfigFontPointSize: nil,
            fallbackBaseFontPointSize: Float(GhosttyConfig().fontSize),
            magnificationPercent: globalFontMagnificationPercent()
        )
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
        guard !manualIO,
              let limit = mobileViewportCellLimit,
              liveSurfaceForGhosttyAccess(reason: reason) != nil else {
            return nil
        }

        let hadAutomaticFit = mobileViewportFontFitState.fittedFontPointSize != nil
        let userAdjustedBaseFontPointSize = mobileViewportFontFitState.baseWasUserAdjusted == true
            ? mobileViewportFontFitState.baseFontPointSize
            : nil
        let surrendered = !hadAutomaticFit || restoreMobileViewportFitFontIfNeeded()
        return MobileViewportFontFitReloadLease(
            columns: limit.columns,
            rows: limit.rows,
            surrendered: surrendered,
            userAdjustedBaseFontPointSize: userAdjustedBaseFontPointSize
        )
    }

    /// Reapplies a prepared mobile viewport constraint from the reloaded font.
    @MainActor
    public func finishMobileViewportFontFitConfigurationReload(
        _ lease: MobileViewportFontFitReloadLease,
        reason: String
    ) {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "\(reason).refit") else {
            mobileViewportFontFitState.clear()
            return
        }
        let configuredFontOverride = lease.surrendered
            ? GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(surface)
            : nil
        if lease.surrendered {
            mobileViewportFontFitState.clear()
            let liveFont = configuredFontOverride ?? configuredMobileViewportFontPointSize()
            mobileViewportFontFitState.begin(
                baseFontPointSize: liveFont,
                configuredFontPointSize: liveFont,
                preservedUserAdjustedBaseFontPointSize: lease.userAdjustedBaseFontPointSize
            )
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
        let lease = prepareMobileViewportFontFitForConfigurationReload(reason: reason)
        reload()
        if let lease {
            finishMobileViewportFontFitConfigurationReload(lease, reason: reason)
        }
    }

    @MainActor
    @discardableResult
    func applyMobileViewportFontPointSize(_ points: Float) -> Bool {
        let action = String(format: "set_font_size:%.3f", points)
        return performBindingAction(action)
    }
}
