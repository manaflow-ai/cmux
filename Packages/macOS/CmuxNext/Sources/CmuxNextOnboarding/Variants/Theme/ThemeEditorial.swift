import AppKit
import CmuxNextDesign

/// Editorial split: a large title, the sentence and a radio list in the
/// left column; the live preview fills the right side edge to edge.
struct ThemeEditorial: OnboardingScreenVariant {
    static let id = "theme.editorial"
    static let step = OnboardingModel.Step.theme
    static let name = "Editorial Bleed"
    static let summary = "Radio list left; the live preview bleeds off the right edge."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        let root = FlippedView()
        let title = OnboardingLabel.make(ThemeVariantStrings.titleColors, font: .systemFont(ofSize: 34, weight: .bold))
        let sentence = OnboardingLabel.make(ThemeVariantStrings.sentenceLive, color: Palette.textSecondary, lines: 2)
        let radios = ThemeChoiceStack(model: model, spacing: 8) { ThemeRadioItem() }
        let list = VariantLayout.scroller(radios)
        // The theme's background fills the right side; the sample sits inside it.
        let side = ThemeBackdrop(model: model)
        let preview = ThemeBoundPreview(model: model, cornerRadius: 0)
        let footer = OnboardingFooter(context: context, glassContinue: false)
        for view in [side, preview, title, sentence, list, footer] { root.addSubview(view) }
        let margin: CGFloat = 48
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor), side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.trailingAnchor.constraint(equalTo: root.trailingAnchor), side.widthAnchor.constraint(equalToConstant: 292),
            preview.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 16), preview.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 52), preview.heightAnchor.constraint(equalToConstant: 132),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(lessThanOrEqualTo: side.leadingAnchor, constant: -32),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            sentence.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sentence.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -32),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -32),
            list.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 24),
            list.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -32),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            radios.widthAnchor.constraint(equalTo: list.contentView.widthAnchor),
        ])
        return root
    }
}
