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

nonisolated enum MobileViewportResetFontPointSize {
    static func resolve(
        surfaceConfigFontPointSize _: Float? = nil,
        runtimeConfigFontPointSize: Float?,
        fallbackBaseFontPointSize: Float,
        magnificationPercent: Int
    ) -> Float {
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
        MobileViewportResetFontPointSize.resolve(
            surfaceConfigFontPointSize: nil,
            runtimeConfigFontPointSize: runtimeConfigFontPointSize(),
            fallbackBaseFontPointSize: Float(GhosttyConfig().fontSize),
            magnificationPercent: globalFontMagnificationPercent()
        )
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
