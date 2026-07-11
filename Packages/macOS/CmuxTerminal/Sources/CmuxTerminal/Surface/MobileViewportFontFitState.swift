import Foundation

enum MobileViewportFontRestorePlan: Equatable {
    case none
    case resetToConfigured
    case resetThenSet(Float)
}

struct MobileViewportFontFitState: Equatable {
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
        baseWasUserAdjusted = !Self.approximatelyEqual(
            baseFontPointSize,
            configuredFontPointSize
        )
    }

    mutating func recordFittedFontPointSize(_ points: Float) {
        fittedFontPointSize = points
    }

    mutating func reconcile(liveFontPointSize: Float, configuredFontPointSize: Float) {
        guard liveFontPointSize.isFinite, liveFontPointSize > 0,
              configuredFontPointSize.isFinite, configuredFontPointSize > 0 else { return }

        if let fittedFontPointSize {
            if !Self.approximatelyEqual(liveFontPointSize, fittedFontPointSize) {
                baseFontPointSize = liveFontPointSize
                self.fittedFontPointSize = nil
                baseWasUserAdjusted = !Self.approximatelyEqual(
                    liveFontPointSize,
                    configuredFontPointSize
                )
                return
            }

            if baseWasUserAdjusted == false,
               !Self.approximatelyEqual(baseFontPointSize, configuredFontPointSize) {
                baseFontPointSize = configuredFontPointSize
            }
            return
        }

        if let baseFontPointSize,
           !Self.approximatelyEqual(liveFontPointSize, baseFontPointSize) {
            self.baseFontPointSize = liveFontPointSize
            baseWasUserAdjusted = !Self.approximatelyEqual(
                liveFontPointSize,
                configuredFontPointSize
            )
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

    mutating func clear() {
        self = .init()
    }

    private static func approximatelyEqual(_ lhs: Float?, _ rhs: Float) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= 0.05
    }
}
