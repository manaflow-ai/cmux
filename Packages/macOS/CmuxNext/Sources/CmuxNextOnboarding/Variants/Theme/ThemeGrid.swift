import AppKit

/// A grid of mini previews, five to a row, each in its own colors, names
/// under them. Centered title; no transition.
struct ThemeGrid: OnboardingScreenVariant {
    static let id = "theme.grid"
    static let step = OnboardingModel.Step.theme
    static let name = "Preview Grid"
    static let summary = "Five-wide grid of mini previews with names."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let grid = ThemeChoiceStack(model: context.model.theme, columns: 5, spacing: 8, lineSpacing: 16) {
            ThemeTile(size: NSSize(width: 104, height: 68))
        }
        let scroll = VariantLayout.scroller(grid)
        let body = NSView()
        body.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            scroll.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 5 * 104 + 4 * 8),
        ])
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.bodyGap = 28
        style.margin = 40
        return OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: ThemeVariantStrings.sentenceLive,
                                       body: body, context: context, style: style)
    }
}
