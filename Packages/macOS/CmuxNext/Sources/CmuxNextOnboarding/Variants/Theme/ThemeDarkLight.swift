import AppKit

/// Two columns, Dark and Light, sorted by each theme's background; rows
/// with a small swatch and a gray selection fill.
struct ThemeDarkLight: OnboardingScreenVariant {
    static let id = "theme.darkLight"
    static let step = OnboardingModel.Step.theme
    static let name = "Dark / Light"
    static let summary = "Dark and Light columns of swatch rows."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        func column(_ title: String, dark: Bool) -> NSView {
            let rows = ThemeChoiceStack(model: model, spacing: 2, fillsWidth: true, include: { ThemeKit.isDark($0.input) == dark }) {
                ThemeRow(style: .plain, height: 32)
            }
            let header = VariantLayout.header(title)
            let scroll = VariantLayout.scroller(rows)
            // Headers line up with the row text, not the selection fill's edge.
            let headerRow = VariantLayout.outset(header, by: -10)
            return VariantLayout.column([headerRow, scroll], spacing: 8, fill: [headerRow, scroll])
        }
        let dark = column(ThemeVariantStrings.dark, dark: true)
        let light = column(ThemeVariantStrings.light, dark: false)
        let body = NSView()
        for view in [dark, light] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            dark.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: -10), dark.topAnchor.constraint(equalTo: body.topAnchor),
            dark.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            light.leadingAnchor.constraint(equalTo: dark.trailingAnchor, constant: 24),
            light.trailingAnchor.constraint(equalTo: body.trailingAnchor), light.topAnchor.constraint(equalTo: body.topAnchor),
            light.bottomAnchor.constraint(equalTo: body.bottomAnchor), light.widthAnchor.constraint(equalTo: dark.widthAnchor),
        ])
        var style = OnboardingScaffold.Style()
        style.titleTop = 44
        style.bodyGap = 24
        return OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: ThemeVariantStrings.sentenceLive,
                                       body: body, context: context, style: style)
    }
}
