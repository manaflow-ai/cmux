import AppKit
import CmuxNextDesign

/// The subtle gray chip that names the machine whose localhost a tab sees
/// (plans/cmux-next/remote-localhost.md section 6), at the trailing end of
/// the omnibar. Hidden while the page is not a loopback origin.
final class MachineBadgeView: NSView {
    private let label = ChromeLabel(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        // Beats the URL field (250) beside it: a long URL truncates, not the chip (cx-k9mc).
        label.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The badge takes the whole press (not its image or label) and the first
    /// one in a browser window that is not key: one click acts, as Chrome's
    /// omnibar buttons do (user, 2026-10-28, "click the star twice").
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The chip's menu (the host's machine actions); nil: no menu.
    var makeMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: self, gap: 4), in: self)
    }

    func show(text: String, help: String) {
        label.stringValue = text
        themedToolTip = help
        setAccessibilityLabel(help)
        updateLayer()
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.hoverFill.cgColor
            label.textColor = Palette.textSecondary
        }
    }
}
