import AppKit
import CmuxNextDesign

/// One grant in the Computer Use window: a rounded card
/// (`OnboardingCardView`) with the grant's full-color macOS icon
/// (`ComputerUseGrantIcon`), its name, one line on what it lets agents do,
/// and one trailing control: "Done" with a checkmark once macOS has it, else
/// an Allow capsule (filled only on the next missing row). The row keeps
/// its size when the control changes, so nothing moves.
final class ComputerUseGrantRow: NSView {
    enum Control: Equatable { case done, allow(primary: Bool), hidden }

    static let height: CGFloat = 84
    static let radius: CGFloat = 22
    private static let padding: CGFloat = 14
    private let allow: OnboardingCapsuleButton
    private let done = NSStackView()
    private let icon = NSImageView()
    private var symbolShown = false
    private var iconLoad: Task<Void, Never>?
    private var loop: RenderLoop?

    init(pane: ComputerUsePermissionPane, icons: ComputerUseGrantIcon.Cache, target: AnyObject?, action: Selector) {
        let name = OnboardingStrings.computerUseName(pane)
        allow = OnboardingCapsuleButton(title: OnboardingStrings.computerUseAllow, style: .plain, target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = OnboardingCardView(cornerRadius: Self.radius)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = OnboardingLabel.make(name, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis))
        let line = OnboardingLabel.make(OnboardingStrings.computerUseLine(pane),
                                        font: Typography.system(size: TypeScale.body), color: Palette.textSecondary, lines: 2)
        let names = NSStackView(views: [title, line])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 12, weight: TypeScale.emphasis)
        check.contentTintColor = Palette.textSecondary
        let doneLabel = OnboardingLabel.make(OnboardingStrings.computerUseDone,
                                             font: Typography.system(size: TypeScale.body, weight: TypeScale.emphasis),
                                             color: Palette.textSecondary)
        done.setViews([doneLabel, check], in: .leading)
        done.spacing = 4
        done.setAccessibilityElement(true)
        done.setAccessibilityLabel(OnboardingStrings.computerUseDone)
        allow.setAccessibilityLabel(OnboardingStrings.computerUseAllowNamed(name))
        allow.setAccessibilityIdentifier("cmux.computerUse.allow.\(pane.rawValue)")
        // `update` shows the one control the grants call for.
        allow.isHidden = true
        done.isHidden = true
        for view in [card, icon, names, allow, done] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // `height` tall, growing only for a line a translation wraps.
        let preferred = heightAnchor.constraint(equalToConstant: Self.height)
        preferred.priority = .defaultLow
        let side = ComputerUseGrantIcon.side
        let padding = Self.padding
        NSLayoutConstraint.activate([
            preferred,
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: side), icon.heightAnchor.constraint(equalToConstant: side),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: padding), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padding),
            names.trailingAnchor.constraint(lessThanOrEqualTo: allow.leadingAnchor, constant: -padding),
            names.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -padding),
            allow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), allow.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22), done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        loadIcon(pane, icons)
        loop = RenderLoop { [weak self] in
            _ = ThemeScope.app.store.input
            self?.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the grant's icon: at once when it is cached, else when the
    /// off-main read lands (the icon's place is kept, so nothing moves).
    private func loadIcon(_ pane: ComputerUsePermissionPane, _ icons: ComputerUseGrantIcon.Cache) {
        if let look = icons.cached(pane) { return show(look) }
        // task-owner: one off-main icon read per row, at most once per window (cached); it only sets the image.
        iconLoad = Task { [weak self] in
            let look = await icons.load(pane)
            self?.show(look)
        }
    }

    private func show(_ look: ComputerUseGrantIcon.Look) {
        switch look {
        case .image(let image):
            symbolShown = false
            icon.symbolConfiguration = nil
            icon.contentTintColor = nil
            icon.image = NSImage(cgImage: image, size: NSSize(width: ComputerUseGrantIcon.side, height: ComputerUseGrantIcon.side))
        case .symbol(let name):
            symbolShown = true
            icon.symbolConfiguration = .init(pointSize: 40, weight: TypeScale.regular)
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            applyColors()
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
            if symbolShown { icon.contentTintColor = Palette.textPrimary }
        }
    }
}
