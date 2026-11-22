import AppKit
import CmuxNextDesign

/// A notice card's switch action (``SidebarNoticeCard/Action/isSwitch``): its title, then a mini switch, sized to
/// fit on the card's button row (the Tidy Up card's "Always", Lawrence 18515, gallery pick T3). Flipping it runs
/// `onFlip`; the card sends the action.
final class SidebarCardSwitch: NSView {
    private let label = ChromeLabel(labelWithString: "")
    private let control = NSSwitch()
    /// Runs when the person flips the switch.
    var onFlip: (() -> Void)?

    init() {
        super.init(frame: .zero)
        control.controlSize = .mini
        control.target = self
        control.action = #selector(flipped)
        label.font = Typography.caption
        label.lineBreakMode = .byClipping
        addSubview(label)
        addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// The switch's title.
    var title: String { label.stringValue }
    /// Whether the switch is on.
    var isOn: Bool { control.state == .on }

    /// Shows `title`, off; `identifier` names the switch for UI tests.
    func configure(title: String, identifier: String?) {
        label.stringValue = title
        control.state = .off
        control.setAccessibilityLabel(title)
        control.setAccessibilityIdentifier(identifier)
        needsLayout = true
    }

    /// Flips the switch as a click does (VoiceOver and tests).
    func flip() {
        control.state = isOn ? .off : .on
        flipped()
    }

    @objc private func flipped() { onFlip?() }

    /// The title's width in its font, plus a point each side so it never truncates.
    private var titleWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? Typography.caption]).width) + 2
    }

    override var fittingSize: NSSize {
        let s = control.fittingSize
        return NSSize(width: titleWidth + Metrics.space1 + s.width, height: max(s.height, ceil(label.intrinsicContentSize.height)))
    }

    override func layout() {
        super.layout()
        let b = bounds, s = control.fittingSize
        // Never left of its own frame: the card gives the switch its whole width or hides it.
        control.frame = NSRect(x: max(0, b.width - s.width), y: (b.height - s.height) / 2, width: s.width, height: s.height)
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: (b.height - h) / 2, width: max(0, control.frame.minX - Metrics.space1), height: h)
    }

    /// Recolors the title for the current theme.
    func applyColors() { performWithTheme { label.textColor = Palette.textSecondary } }
}
