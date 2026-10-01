import AppKit
import CmuxNextDesign

/// Default browser: what opens links now, and one button. macOS shows its
/// own confirmation.
final class DefaultBrowserStepView: NSView {
    private let model: DefaultAppsStepModel
    private let status = OnboardingLabel.make(color: Palette.textSecondary, lines: 2)
    private var button: NSButton!
    private var loop: RenderLoop?

    init(model: DefaultAppsStepModel) {
        self.model = model
        super.init(frame: .zero)
        button = OnboardingControl.button(OnboardingStrings.makeDefaultBrowser, target: self, action: #selector(press))
        let stack = NSStackView(views: [status, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func press() { model.request(.webBrowser) }

    private func render() {
        let claimed = model.isClaimed(.webBrowser)
        let pending = model.pending.contains(.webBrowser)
        button.isHidden = claimed
        button.isEnabled = !pending
        if let error = model.errors[.webBrowser] {
            status.stringValue = OnboardingStrings.systemRefused(error)
        } else if claimed {
            status.stringValue = OnboardingStrings.isDefaultBrowser
        } else if pending {
            status.stringValue = OnboardingStrings.waiting
        } else {
            status.stringValue = model.currentBrowserName.map(OnboardingStrings.currentBrowser) ?? ""
        }
        status.isHidden = status.stringValue.isEmpty
    }
}
