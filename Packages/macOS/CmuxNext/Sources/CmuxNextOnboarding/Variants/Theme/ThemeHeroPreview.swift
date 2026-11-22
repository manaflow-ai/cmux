import AppKit

/// A big live terminal preview, centered, with one pop-up of theme names
/// under it. No sentence: the preview is the explanation.
struct ThemeHeroPreview: OnboardingScreenVariant {
    static let id = "theme.heroPreview"
    static let step = OnboardingModel.Step.theme
    static let name = "Hero Preview"
    static let summary = "Large live preview, one pop-up of names under it."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        let preview = ThemeBoundPreview(model: model)
        let popUp = ThemePopUp(model: model)
        let body = NSView()
        for view in [preview, popUp] { body.addSubview(view) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: body.topAnchor), preview.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: body.trailingAnchor), preview.heightAnchor.constraint(equalToConstant: 152),
            popUp.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 24), popUp.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.titleSize = 28
        style.margin = 56
        style.titleTop = 52
        style.bodyGap = 28
        return OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: nil, body: body, context: context, style: style)
    }
}
