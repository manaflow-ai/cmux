nonisolated enum MobileViewportFontRestorePlan: Equatable {
    case none
    case resetToConfigured
    case resetThenSet(Float)
}

nonisolated enum MobileViewportFontRestoreOutcome: Equatable {
    case notNeeded
    case failed
    case restored
    case resetAfterBaseReapplyFailure

    var surrenderedAutomaticFit: Bool {
        switch self {
        case .restored, .resetAfterBaseReapplyFailure:
            true
        case .notNeeded, .failed:
            false
        }
    }
}

nonisolated struct MobileViewportFontRestorer {
    static func restore(
        plan: MobileViewportFontRestorePlan,
        reset: () -> Bool,
        set: (Float) -> Bool
    ) -> MobileViewportFontRestoreOutcome {
        switch plan {
        case .none:
            return .notNeeded
        case .resetToConfigured:
            return reset() ? .restored : .failed
        case .resetThenSet(let baseFontPointSize):
            guard reset() else { return .failed }
            return set(baseFontPointSize) ? .restored : .resetAfterBaseReapplyFailure
        }
    }
}
