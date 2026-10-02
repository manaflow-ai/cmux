import AppKit

/// Only the names, centered, in large text; the window itself re-themes
/// live as the preview. Small title, no transition.
struct ThemeMinimalList: OnboardingScreenVariant {
    static let id = "theme.minimalList"
    static let step = OnboardingModel.Step.theme
    static let name = "Names Only"
    static let summary = "A centered list of names; the window is the preview."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let names = ThemeChoiceStack(model: context.model.theme, spacing: 0, fillsWidth: true) { ThemeRow(style: .text, height: 30) }
        let scroll = VariantLayout.scroller(names)
        let body = NSView()
        body.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            scroll.centerXAnchor.constraint(equalTo: body.centerXAnchor), scroll.widthAnchor.constraint(equalToConstant: 280),
        ])
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.titleSize = 17
        style.titleTop = 48
        style.margin = 64
        style.bodyGap = 24
        style.glassContinue = false
        return OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: ThemeVariantStrings.sentenceWindow,
                                       body: body, context: context, style: style)
    }
}
