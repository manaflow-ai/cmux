import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One grant as a card: its symbol, name and one line on what it lets
/// Computer Use do, and on the right its state (`PermissionCardState`):
/// the filled Allow for the next grant to give, a bordered Allow for a later
/// one, or a green check with "Allowed" once macOS has it. The card draws the
/// shared card glass (`CardSurfaceView`), so its text stays legible over any
/// backdrop, and keeps its size when the state changes, so nothing moves.
final class PermissionRow: NSView {
    static let height: CGFloat = 64
    /// The filled Allow (`PermissionCardState.next`).
    let primaryAllow: NSButton
    /// The bordered Allow (`PermissionCardState.later`).
    let secondaryAllow: NSButton
    /// The check and "Allowed" (`PermissionCardState.granted`).
    let allowed = NSStackView()
    private(set) var state: PermissionCardState?

    init(symbol: String, title: String, detail: String, target: AnyObject?, action: Selector) {
        primaryAllow = OnboardingControl.button(OnboardingStrings.computerUseAllow, prominent: true, target: target, action: action)
        secondaryAllow = OnboardingControl.button(OnboardingStrings.computerUseAllow, target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = CardSurfaceView(cornerRadius: 12)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = Palette.textPrimary
        let name = OnboardingLabel.make(title, font: Typography.bodyEmphasized)
        let line = OnboardingLabel.make(detail, font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
        let names = NSStackView(views: [name, line])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        let check = NSImageView(image: NSImage.icon(.statusComplete, size: 16))
        check.contentTintColor = Palette.success
        let allowedLabel = OnboardingLabel.make(OnboardingStrings.computerUseAllowed, color: Palette.textSecondary)
        allowedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        allowed.setViews([check, allowedLabel], in: .leading)
        allowed.spacing = 6
        allowed.setAccessibilityElement(true)
        allowed.setAccessibilityLabel(OnboardingStrings.computerUseAllowed)
        for button in [primaryAllow, secondaryAllow] {
            button.setAccessibilityLabel(OnboardingStrings.computerUseAllowNamed(title))
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view in [card, icon, names, primaryAllow, secondaryAllow, allowed] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // `height` tall, growing only for a detail line a translation wraps.
        let preferred = heightAnchor.constraint(equalToConstant: Self.height)
        preferred.priority = .defaultLow
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            preferred,
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            names.trailingAnchor.constraint(lessThanOrEqualTo: secondaryAllow.leadingAnchor, constant: -16),
            names.trailingAnchor.constraint(lessThanOrEqualTo: primaryAllow.leadingAnchor, constant: -16),
            names.trailingAnchor.constraint(lessThanOrEqualTo: allowed.leadingAnchor, constant: -16),
            primaryAllow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            primaryAllow.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryAllow.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            // A bordered push button draws inside a 6 pt bezel margin: this lines its edge up with the filled one.
            secondaryAllow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 6),
            secondaryAllow.centerYAnchor.constraint(equalTo: centerYAnchor),
            secondaryAllow.widthAnchor.constraint(equalTo: primaryAllow.widthAnchor, constant: 12),
            allowed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 4),
            allowed.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(state: .later)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `state` on the card's right; the card's size does not change.
    func update(state: PermissionCardState) {
        guard state != self.state else { return }
        self.state = state
        primaryAllow.isHidden = state != .next
        secondaryAllow.isHidden = state != .later
        allowed.isHidden = state != .granted
    }
}
