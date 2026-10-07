import AppKit
import CmuxNextDesign

/// Settings-style: a sidebar list of swatch rows on the left, the live
/// preview and the theme's 16 ANSI colors on the right.
struct ThemeSidebar: OnboardingScreenVariant {
    static let id = "theme.sidebar"
    static let step = OnboardingModel.Step.theme
    static let name = "Sidebar"
    static let summary = "Sidebar of themes; preview and ANSI colors on the right."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        let root = FlippedView()
        let title = OnboardingLabel.make(OnboardingStrings.themeTitle, font: .systemFont(ofSize: 22, weight: .semibold))
        let rows = ThemeChoiceStack(model: model, spacing: 2, fillsWidth: true) { ThemeRow(style: .plain, height: 32) }
        let list = VariantLayout.scroller(rows)
        let preview = ThemeBoundPreview(model: model)
        let strip = ThemePaletteStrip(model: model)
        let footer = OnboardingFooter(context: context)
        for view in [title, list, preview, strip, footer] { root.addSubview(view) }
        // Window coordinates minus the panel's 12 pt inset: 40 pt reads as the usual 52 pt title top.
        let margin: CGFloat = 28
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin - 10),
            list.widthAnchor.constraint(equalToConstant: 196),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
            list.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            preview.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 24),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            preview.topAnchor.constraint(equalTo: list.topAnchor), preview.heightAnchor.constraint(equalToConstant: 196),
            strip.leadingAnchor.constraint(equalTo: preview.leadingAnchor), strip.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            strip.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 16), strip.heightAnchor.constraint(equalToConstant: 20),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            rows.widthAnchor.constraint(equalTo: list.contentView.widthAnchor),
        ])
        return root
    }
}
