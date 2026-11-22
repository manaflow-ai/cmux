import AppKit
import CmuxNextDesign

/// One theme at a time: a large preview, and under it the name between
/// two round glass arrow buttons that step through the themes.
struct ThemeStepper: OnboardingScreenVariant {
    static let id = "theme.stepper"
    static let step = OnboardingModel.Step.theme
    static let name = "Stepper"
    static let summary = "One preview; glass arrows step through the themes."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.alignment = .center
        style.titleSize = 28
        style.margin = 64
        style.titleTop = 52
        style.bodyGap = 28
        return OnboardingScaffold.make(title: ThemeVariantStrings.titleLook, subtitle: nil,
                                       body: ThemeStepperBody(model: context.model.theme), context: context, style: style)
    }
}

/// Preview, arrows and the name of the theme on show.
final class ThemeStepperBody: NSView {
    private let model: ThemeStepModel
    private let label = OnboardingLabel.make(font: .systemFont(ofSize: 15, weight: .medium))
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        let preview = ThemeBoundPreview(model: model)
        let back = arrow("chevron.left", ThemeVariantStrings.previous, #selector(previous))
        let forward = arrow("chevron.right", ThemeVariantStrings.next, #selector(next))
        label.alignment = .center
        for view in [preview, back, label, forward] { addSubview(view) }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor), preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            preview.widthAnchor.constraint(equalTo: widthAnchor), preview.heightAnchor.constraint(equalToConstant: 180),
            label.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 28), label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(equalToConstant: 232),
            back.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12), back.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            forward.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            forward.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        loop = RenderLoop { [weak self] in
            guard let self else { return }
            label.stringValue = ThemeKit.name(self.model.selectedChoice)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func previous() { ThemeKit.step(model, by: -1) }
    @objc private func next() { ThemeKit.step(model, by: 1) }

    private func arrow(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .glass
        button.controlSize = .large
        button.contentTintColor = Palette.textPrimary
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }
}
