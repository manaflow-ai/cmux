import AppKit
import CmuxNextDesign

/// One grant in the Computer Use window: a solid rounded row with the
/// grant's system icon, its name, one line on what it lets agents do, and
/// one trailing control: "Done" with a checkmark once macOS has it, else
/// an Allow capsule (filled only on the next missing row). The row keeps
/// its size when the control changes, so nothing moves.
final class ComputerUseGrantRow: NSView {
    enum Control: Equatable { case done, allow(primary: Bool), hidden }

    static let height: CGFloat = 56
    static let radius: CGFloat = 12
    private let allow: OnboardingCapsuleButton
    private let done = NSStackView()
    private let icon = NSImageView()
    private var loop: RenderLoop?

    init(pane: ComputerUsePermissionPane, target: AnyObject?, action: Selector) {
        let name = OnboardingStrings.computerUseName(pane)
        allow = OnboardingCapsuleButton(title: OnboardingStrings.computerUseAllow, style: .plain, target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Self.radius
        icon.image = NSImage(systemSymbolName: Self.symbol(pane), accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        let title = OnboardingLabel.make(name, font: Typography.system(size: TypeScale.body, weight: TypeScale.emphasis))
        let line = OnboardingLabel.make(OnboardingStrings.computerUseLine(pane),
                                        font: Typography.system(size: TypeScale.detail), color: Palette.textSecondary, lines: 2)
        let names = NSStackView(views: [title, line])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        check.contentTintColor = Palette.textSecondary
        let doneLabel = OnboardingLabel.make(OnboardingStrings.computerUseDone, color: Palette.textSecondary)
        done.setViews([doneLabel, check], in: .leading)
        done.spacing = 4
        done.setAccessibilityElement(true)
        done.setAccessibilityLabel(OnboardingStrings.computerUseDone)
        allow.setAccessibilityLabel(OnboardingStrings.computerUseAllowNamed(name))
        allow.setAccessibilityIdentifier("cmux.computerUse.allow.\(pane.rawValue)")
        // `update` shows the one control the grants call for.
        allow.isHidden = true
        done.isHidden = true
        for view in [icon, names, allow, done] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // `height` tall, growing only for a line a translation wraps.
        let preferred = heightAnchor.constraint(equalToConstant: Self.height)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferred,
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            names.trailingAnchor.constraint(lessThanOrEqualTo: allow.leadingAnchor, constant: -12),
            names.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -12),
            allow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), allow.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        loop = RenderLoop { [weak self] in
            _ = ThemeScope.app.store.input
            self?.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: "accessibility"
        case .screenRecording: "camera.viewfinder"
        }
    }

    private(set) var control: Control = .hidden

    func update(_ next: Control) {
        guard next != control else { return }
        control = next
        done.isHidden = next != .done
        switch next {
        case .allow(let primary):
            allow.isHidden = false
            allow.setStyle(primary ? .primary : .plain)
        case .done, .hidden:
            allow.isHidden = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
            icon.contentTintColor = Palette.textPrimary
        }
    }
}
