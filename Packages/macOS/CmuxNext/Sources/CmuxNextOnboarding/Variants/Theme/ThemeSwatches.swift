import AppKit
import CmuxNextDesign

/// A live preview, a centered row of round swatches in each theme's own
/// colors, and the picked theme's name under them.
struct ThemeSwatches: OnboardingScreenVariant {
    static let id = "theme.swatches"
    static let step = OnboardingModel.Step.theme
    static let name = "Swatch Row"
    static let summary = "Preview, a row of round swatches, the name below."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.margin = 48
        style.bodyGap = 28
        return OnboardingScaffold.make(title: ThemeVariantStrings.titleColors, subtitle: nil,
                                       body: ThemeSwatchesBody(model: model), context: context, style: style)
    }
}

/// The preview, the swatches and the name label that follows the pick.
final class ThemeSwatchesBody: NSView {
    private let model: ThemeStepModel
    private let label = OnboardingLabel.make(font: .systemFont(ofSize: 13, weight: .medium))
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        let preview = ThemeBoundPreview(model: model)
        let swatches = ThemeChoiceStack(model: model, orientation: .horizontal, spacing: 4) { ThemeSwatchDot(diameter: 40) }
        label.alignment = .center
        for view in [preview, swatches, label] { addSubview(view) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor), preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.heightAnchor.constraint(equalToConstant: 140),
            swatches.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 24),
            swatches.centerXAnchor.constraint(equalTo: centerXAnchor),
            swatches.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            label.topAnchor.constraint(equalTo: swatches.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        loop = RenderLoop { [weak self] in
            guard let self else { return }
            label.stringValue = ThemeKit.name(self.model.selectedChoice)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
