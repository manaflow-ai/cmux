import Foundation

enum MobileViewportFontRestorePlan: Equatable {
    case none
    case setAbsolute(Float)
    case resetToConfigured
    case resetThenSet(Float)
}

struct MobileViewportFontFitState: Equatable {
    var baseFontPointSize: Float?
    var fittedFontPointSize: Float?
    var baseWasUserAdjusted: Bool?

    mutating func begin(baseFontPointSize: Float, configuredFontPointSize: Float) {
        guard self.baseFontPointSize == nil else { return }
        self.baseFontPointSize = baseFontPointSize
    }

    mutating func recordFittedFontPointSize(_ points: Float) {
        fittedFontPointSize = points
    }

    mutating func reconcile(liveFontPointSize: Float, configuredFontPointSize: Float) {}

    func resolvedCurrentFontPointSize(liveFontPointSize: Float) -> Float {
        fittedFontPointSize ?? liveFontPointSize
    }

    func restorePlan(configuredFontPointSize: Float) -> MobileViewportFontRestorePlan {
        guard fittedFontPointSize != nil, let baseFontPointSize else { return .none }
        return .setAbsolute(baseFontPointSize)
    }
}
