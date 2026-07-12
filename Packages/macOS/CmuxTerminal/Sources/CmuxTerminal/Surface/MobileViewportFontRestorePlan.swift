enum MobileViewportFontRestorePlan: Equatable {
    case none
    case resetToConfigured
    case resetThenSet(Float)
}
