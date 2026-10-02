import AppKit
import CmuxNextDesign

/// The whole window is the terminal, in the picked theme; a floating glass
/// bar at the bottom (clear of the text) holds the title, a pop-up of
/// names and the footer.
struct ThemeImmersive: OnboardingScreenVariant {
    static let id = "theme.immersive"
    static let step = OnboardingModel.Step.theme
    static let name = "Immersive"
    static let summary = "Full-window terminal preview; floating glass picker bar."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.theme
        let root = FlippedView()
        // The backdrop is the terminal's background; the sample text starts
        // below the close button and ends well above the bar.
        let backdrop = ThemeBackdrop(model: model)
        let terminal = ThemeBoundPreview(model: model, cornerRadius: 0)
        let inner = NSView()
        let title = OnboardingLabel.make(OnboardingStrings.themeTitle, font: .systemFont(ofSize: 17, weight: .semibold))
        let popUp = ThemePopUp(model: model)
        let footer = OnboardingFooter(context: context)
        for view in [title, popUp, footer] { inner.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 24),
            title.centerYAnchor.constraint(equalTo: popUp.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: popUp.leadingAnchor, constant: -16),
            popUp.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -24),
            popUp.topAnchor.constraint(equalTo: inner.topAnchor, constant: 20),
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            footer.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -24),
            footer.topAnchor.constraint(equalTo: popUp.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -16),
        ])
        let bar = Glass.makePanel(content: inner, cornerRadius: 20)
        for view in [backdrop, terminal, bar] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor), backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            terminal.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            terminal.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -16),
            terminal.heightAnchor.constraint(equalToConstant: 132),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        return root
    }
}

/// Fills with the picked theme's background.
final class ThemeBackdrop: NSView {
    private let model: ThemeStepModel
    private var loop: RenderLoop?

    init(model: ThemeStepModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        loop = RenderLoop { [weak self] in
            _ = self?.model.selectedChoice
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        model.selectedChoice.input.background.nsColor.setFill()
        dirtyRect.fill()
    }
}
