import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The leaf's card: "Energy Saver is on", why, what it changes, and "Turn Off for Now".
@MainActor
final class SidebarEnergyCardView: NSView, HoverCardTextReporting {
    static let width: CGFloat = 260

    let turnOff = SidebarCardTextButton()
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private let title = ChromeLabel(labelWithString: Strings.energySaverOn)
    private let reasonLabel = ChromeLabel(wrappingLabelWithString: "")
    private let effect = ChromeLabel(wrappingLabelWithString: Strings.energySaverEffect)
    private var tracking: NSTrackingArea?

    var reportedLines: [String] { [title.stringValue, reasonLabel.stringValue, effect.stringValue, turnOff.title] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Typography.bodyEmphasized
        reasonLabel.font = Typography.body
        effect.font = Typography.caption
        turnOff.configure(title: Strings.energySaverTurnOffForNow, help: Strings.energySaverTurnOffForNowHelp(onBattery: false))
        let text = Self.width - 2 * Metrics.space3
        for label in [reasonLabel, effect] { label.preferredMaxLayoutWidth = text }
        let stack = NSStackView(views: [title, reasonLabel, effect, turnOff])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.setCustomSpacing(Metrics.space2, after: effect)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Metrics.space3
        turnOff.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            reasonLabel.widthAnchor.constraint(equalToConstant: text),
            effect.widthAnchor.constraint(equalToConstant: text),
            // The text button sits on the text's leading edge: its hover fill's inset hangs outside it.
            turnOff.widthAnchor.constraint(equalToConstant: turnOff.fittingWidth),
            turnOff.heightAnchor.constraint(equalToConstant: SidebarCardTextButton.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.energySaverOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `reason`, with `batteryPercent` for a low battery, and what ends "Turn Off for Now": on
    /// battery, plugging the Mac in or a setting change; plugged in, only a setting change
    /// (`EnergyPolicyResolver.update`).
    func configure(reason: EnergyPolicy.Reason, batteryPercent: Int?, onBattery: Bool) {
        reasonLabel.stringValue = Strings.energySaverReason(reason, batteryPercent: batteryPercent)
        turnOff.configure(title: Strings.energySaverTurnOffForNow, help: Strings.energySaverTurnOffForNowHelp(onBattery: onBattery))
    }

    func applyColors() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            reasonLabel.textColor = Palette.textSecondary
            effect.textColor = Palette.textTertiary
        }
        turnOff.needsDisplay = true
    }

    // visibility-walk-allow: sets the labels' text colors and invalidates the button only (no layout)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerEnter?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
}

extension Strings {
    /// The leaf's VoiceOver label.
    static var energySaver: String { String(localized: "sidebar.energySaver", defaultValue: "Energy Saver", bundle: .module) }
    /// The card's title.
    static var energySaverOn: String { String(localized: "sidebar.energySaver.on", defaultValue: "Energy Saver is on", bundle: .module) }
    /// What the saver changes, and what it leaves alone.
    static var energySaverEffect: String {
        String(localized: "sidebar.energySaver.effect",
               defaultValue: "cmux draws fewer frames and wakes less often. Typing and scrolling are not slowed.", bundle: .module)
    }
    static var energySaverTurnOffForNow: String {
        String(localized: "sidebar.energySaver.turnOffForNow", defaultValue: "Turn Off for Now", bundle: .module)
    }
    /// What ends "Turn Off for Now" (its tooltip and VoiceOver label): plugging the Mac in only does
    /// while it runs on battery.
    static func energySaverTurnOffForNowHelp(onBattery: Bool) -> String {
        if onBattery {
            return String(localized: "sidebar.energySaver.turnOffForNow.help",
                          defaultValue: "Keeps Energy Saver off until you plug in your Mac or change the Energy Saver setting.",
                          bundle: .module)
        }
        return String(localized: "sidebar.energySaver.turnOffForNow.help.pluggedIn",
                      defaultValue: "Keeps Energy Saver off until you change the Energy Saver setting.", bundle: .module)
    }
    /// Why the saver is on; a low battery names its charge when it is known.
    static func energySaverReason(_ reason: EnergyPolicy.Reason, batteryPercent: Int? = nil) -> String {
        switch reason {
        case .lowPowerMode:
            return String(localized: "sidebar.energySaver.reason.lowPowerMode", defaultValue: "Low Power Mode is on.", bundle: .module)
        case .battery:
            if let batteryPercent {
                return String(localized: "sidebar.energySaver.reason.batteryPercent",
                              defaultValue: "The battery is at \(batteryPercent)%.", bundle: .module)
            }
            return String(localized: "sidebar.energySaver.reason.battery", defaultValue: "The battery is low.", bundle: .module)
        case .thermal:
            return String(localized: "sidebar.energySaver.reason.thermal", defaultValue: "Your Mac is hot and running on battery.",
                          bundle: .module)
        case .setting:
            return String(localized: "sidebar.energySaver.reason.setting", defaultValue: "Your Energy Saver setting turned it on.",
                          bundle: .module)
        }
    }
}
