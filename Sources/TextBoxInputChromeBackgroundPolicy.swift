enum TextBoxInputChromeBackgroundStyle: Equatable {
    case materialFallback
    case swiftUIGlass
}

enum TextBoxInputChromeBackgroundPolicy {
    static func style(glassEffectAvailable: Bool) -> TextBoxInputChromeBackgroundStyle {
        glassEffectAvailable ? .swiftUIGlass : .materialFallback
    }
}
