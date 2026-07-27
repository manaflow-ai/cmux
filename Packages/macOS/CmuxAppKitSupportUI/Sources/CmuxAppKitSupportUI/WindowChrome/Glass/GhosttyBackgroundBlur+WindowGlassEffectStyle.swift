public import CmuxFoundation

extension GhosttyBackgroundBlur {
    /// The window-glass style for this blur mode, or `nil` when the mode is not
    /// backed by native macOS glass.
    public var windowGlassStyle: WindowGlassEffectStyle? {
        switch self {
        case .macosGlassRegular:
            return .regular
        case .macosGlassClear:
            return .clear
        case .disabled, .radius:
            return nil
        }
    }
}
