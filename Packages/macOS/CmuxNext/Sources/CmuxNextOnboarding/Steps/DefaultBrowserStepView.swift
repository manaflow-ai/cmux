import AppKit
import CmuxNextDesign

/// Step 3: one clear action. macOS shows its own confirmation.
final class DefaultBrowserStepView: NSView {
    private let model: DefaultAppsStepModel
    private let status = OnboardingLabel.make(font: Typography.bodyEmphasized)
    private let detail = OnboardingLabel.make(font: Typography.caption, color: Palette.textTertiary, lines: 2)
    private let button: OnboardingButton
    private let check = NSImageView()
    private var loop: RenderLoop?

    init(model: DefaultAppsStepModel) {
        self.model = model
        button = OnboardingButton(OnboardingStrings.makeDefaultBrowser, style: .primary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.onPress = { [weak model] in model?.request(.webBrowser) }
        let hero = HeroSymbolView(symbol: "globe")
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = Palette.success
        check.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = NSStackView(views: [check, status])
        statusRow.spacing = Metrics.space3
        let stack = NSStackView(views: [hero, statusRow, button, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space5
        stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: hero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Metrics.space6),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        detail.alignment = .center
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let claimed = model.isClaimed(.webBrowser)
        let pending = model.pending.contains(.webBrowser)
        check.isHidden = !claimed
        button.isHidden = claimed
        button.isEnabled = !pending
        if claimed {
            status.stringValue = OnboardingStrings.isDefaultBrowser
        } else {
            status.stringValue = model.currentBrowserName.map(OnboardingStrings.currentBrowser) ?? ""
        }
        if let error = model.errors[.webBrowser] {
            detail.stringValue = OnboardingStrings.systemRefused(error)
        } else {
            detail.stringValue = claimed ? "" : (pending ? OnboardingStrings.waiting : OnboardingStrings.confirmHint)
        }
    }
}

/// A large SF Symbol on a soft rounded square: the step's picture.
final class HeroSymbolView: ThemedView {
    init(symbol: String) {
        super.init(frame: .zero)
        fill = { Palette.hoverFill }
        border = { Palette.separator }
        cornerRadius = Metrics.space6 + Metrics.space2
        let image = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.space6 * 2, weight: .light)
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image.contentTintColor = Palette.textPrimary
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        let side = Metrics.space6 * 4.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
