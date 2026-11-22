import AppKit

/// Two columns of rows, each row painted in its theme: background, name in
/// the theme's foreground, six ANSI dots. The picked row is ringed.
struct ThemeTintedRows: OnboardingScreenVariant {
    static let id = "theme.tintedRows"
    static let step = OnboardingModel.Step.theme
    static let name = "Tinted Rows"
    static let summary = "Two columns of rows, each painted in its own theme."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let rows = ThemeChoiceStack(model: context.model.theme, columns: 2, spacing: 12, lineSpacing: 4, fillsWidth: true) {
            ThemeRow(style: .tinted, height: 48)
        }
        let body = VariantLayout.outset(rows)
        var style = OnboardingScaffold.Style()
        style.bodyGap = 20
        return OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: OnboardingStrings.themeSubtitle,
                                       body: body, context: context, style: style)
    }
}
