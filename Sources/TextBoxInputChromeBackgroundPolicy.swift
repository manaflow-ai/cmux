enum TextBoxInputChromeBackgroundStyle: Equatable {
    case materialFallback
    case swiftUIGlass
}

enum TextBoxInputChromeBackgroundPolicy {
    static func style(glassEffectAvailable _: Bool) -> TextBoxInputChromeBackgroundStyle {
        .materialFallback
    }
}
