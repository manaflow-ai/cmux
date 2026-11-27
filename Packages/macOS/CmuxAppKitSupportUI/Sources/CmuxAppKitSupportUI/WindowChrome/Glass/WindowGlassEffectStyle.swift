/// Native window-glass style applied when `NSGlassEffectView` is available.
public enum WindowGlassEffectStyle: Equatable, Sendable {
    /// The default macOS glass appearance.
    case regular

    /// The clear macOS glass appearance used by Ghostty's clear glass mode.
    case clear

    var rawNSGlassEffectViewStyle: Int {
        switch self {
        case .regular:
            return 0
        case .clear:
            return 1
        }
    }
}
