import Foundation

private func mobileViewportFontSizesApproximatelyEqual(_ lhs: Float?, _ rhs: Float) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= 0.05
}

nonisolated struct MobileViewportLiveFont: Equatable {
    let pointSize: Float
    let isAdjusted: Bool
}

nonisolated struct MobileViewportFontFitState: Equatable {
    var baseFontPointSize: Float?
    var fittedFontPointSize: Float?
    var baseWasUserAdjusted: Bool?
    private var needsLiveFontProbe = true

    init(
        baseFontPointSize: Float? = nil,
        fittedFontPointSize: Float? = nil,
        baseWasUserAdjusted: Bool? = nil
    ) {
        self.baseFontPointSize = baseFontPointSize
        self.fittedFontPointSize = fittedFontPointSize
        self.baseWasUserAdjusted = baseWasUserAdjusted
    }

    mutating func cellMetricsDidChange() {
        needsLiveFontProbe = true
    }

    mutating func consumeLiveFontProbeRequest() -> Bool {
        defer { needsLiveFontProbe = false }
        return needsLiveFontProbe
    }

    mutating func suppressLiveFontProbeUntilMetricsChange() {
        needsLiveFontProbe = false
    }

    @discardableResult
    mutating func reconcilePendingLiveFontProbe(
        configuredFontPointSize: Float,
        probe: () -> MobileViewportLiveFont?
    ) -> MobileViewportLiveFont? {
        guard consumeLiveFontProbeRequest() else { return nil }
        guard let liveFont = probe() else {
            needsLiveFontProbe = true
            return nil
        }
        reconcile(
            liveFont: liveFont,
            configuredFontPointSize: configuredFontPointSize
        )
        return liveFont
    }

    mutating func begin(
        liveFont: MobileViewportLiveFont,
        configuredFontPointSize: Float,
        preservedUserAdjustedBaseFontPointSize: Float? = nil
    ) {
        guard self.baseFontPointSize == nil else { return }
        if let preservedUserAdjustedBaseFontPointSize,
           preservedUserAdjustedBaseFontPointSize.isFinite,
           preservedUserAdjustedBaseFontPointSize > 0 {
            self.baseFontPointSize = preservedUserAdjustedBaseFontPointSize
            baseWasUserAdjusted = true
            return
        }
        baseFontPointSize = liveFont.pointSize
        baseWasUserAdjusted = liveFont.isAdjusted
    }

    mutating func begin(
        baseFontPointSize: Float,
        configuredFontPointSize: Float,
        preservedUserAdjustedBaseFontPointSize: Float? = nil
    ) {
        guard self.baseFontPointSize == nil else { return }
        if let preservedUserAdjustedBaseFontPointSize,
           preservedUserAdjustedBaseFontPointSize.isFinite,
           preservedUserAdjustedBaseFontPointSize > 0 {
            self.baseFontPointSize = preservedUserAdjustedBaseFontPointSize
            baseWasUserAdjusted = true
            return
        }
        self.baseFontPointSize = baseFontPointSize
        baseWasUserAdjusted = !mobileViewportFontSizesApproximatelyEqual(
            baseFontPointSize,
            configuredFontPointSize
        )
    }

    mutating func recordFittedFontPointSize(_ points: Float) {
        fittedFontPointSize = points
    }

    mutating func reconcile(liveFontPointSize: Float, configuredFontPointSize: Float) {
        reconcile(
            liveFont: MobileViewportLiveFont(
                pointSize: liveFontPointSize,
                isAdjusted: !mobileViewportFontSizesApproximatelyEqual(
                    liveFontPointSize,
                    configuredFontPointSize
                )
            ),
            configuredFontPointSize: configuredFontPointSize
        )
    }

    mutating func reconcile(
        liveFont: MobileViewportLiveFont,
        configuredFontPointSize: Float
    ) {
        let liveFontPointSize = liveFont.pointSize
        guard liveFontPointSize.isFinite, liveFontPointSize > 0,
              configuredFontPointSize.isFinite, configuredFontPointSize > 0 else { return }

        if let fittedFontPointSize {
            if !mobileViewportFontSizesApproximatelyEqual(liveFontPointSize, fittedFontPointSize) {
                baseFontPointSize = liveFontPointSize
                self.fittedFontPointSize = nil
                baseWasUserAdjusted = liveFont.isAdjusted
                return
            }

            if baseWasUserAdjusted == false,
               !mobileViewportFontSizesApproximatelyEqual(baseFontPointSize, configuredFontPointSize) {
                baseFontPointSize = configuredFontPointSize
            }
            return
        }

        if let baseFontPointSize {
            if !mobileViewportFontSizesApproximatelyEqual(liveFontPointSize, baseFontPointSize) ||
                baseWasUserAdjusted != liveFont.isAdjusted {
                self.baseFontPointSize = liveFontPointSize
                baseWasUserAdjusted = liveFont.isAdjusted
            }
        }
    }

    func resolvedCurrentFontPointSize(liveFontPointSize: Float) -> Float {
        liveFontPointSize
    }

    func restorePlan(configuredFontPointSize: Float) -> MobileViewportFontRestorePlan {
        guard fittedFontPointSize != nil, let baseFontPointSize else { return .none }
        if baseWasUserAdjusted == true {
            return .resetThenSet(baseFontPointSize)
        }
        return .resetToConfigured
    }

    mutating func reconcileRestoreOutcome(_ outcome: MobileViewportFontRestoreOutcome) {
        switch outcome {
        case .notNeeded, .restored, .resetAfterBaseReapplyFailure:
            clear()
        case .failed:
            break
        }
    }

    mutating func clear() {
        self = .init()
    }
}
