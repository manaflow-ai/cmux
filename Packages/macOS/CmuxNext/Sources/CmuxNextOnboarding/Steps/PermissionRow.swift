import AppKit
import CmuxNextDesign

/// One grant: its symbol, name and one line on what it lets computer use
/// do, then Allow, or a Done checkmark once macOS has it. The row keeps its
/// size when Allow turns into Done, so nothing moves.
final class PermissionRow: NSView {
    static let height: CGFloat = 56
    private let allow: NSButton
    private let done = NSStackView()

    init(symbol: String, title: String, detail: String, target: AnyObject?, action: Selector) {
        allow = OnboardingControl.button(OnboardingStrings.computerUseAllow, target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = Palette.textSecondary
        let name = OnboardingLabel.make(title)
        let line = OnboardingLabel.make(detail, font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
        let names = NSStackView(views: [name, line])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        check.contentTintColor = Palette.success
        done.setViews([check, OnboardingLabel.make(OnboardingStrings.computerUseDone, color: Palette.textSecondary)], in: .leading)
        done.spacing = 5
        allow.setAccessibilityLabel(OnboardingStrings.computerUseAllowNamed(title))
        for view in [icon, names, allow, done] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // `height` tall, growing only for a detail line a translation wraps.
        let preferred = heightAnchor.constraint(equalToConstant: Self.height)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferred,
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            names.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), names.centerYAnchor.constraint(equalTo: centerYAnchor),
            names.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            names.trailingAnchor.constraint(lessThanOrEqualTo: allow.leadingAnchor, constant: -16),
            allow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), allow.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(granted: Bool) {
        allow.isHidden = granted
        done.isHidden = !granted
    }
}
