public import AppKit
public import CmuxNextDesign

/// How the omnibar shows a tab's browser profile: its icon or first letter
/// on its color (plans/cmux-next/data-model.md section 5).
public struct BrowserProfileBadge: Hashable, Sendable {
    public var monogram: String
    public var color: GroupColor?
    /// The profile's name, for the tooltip and VoiceOver.
    public var name: String

    public init(monogram: String, color: GroupColor?, name: String) {
        self.monogram = monogram
        self.color = color
        self.name = name
    }
}

/// The small round avatar at the trailing end of the omnibar that names the
/// tab's browser profile. Hidden while only one profile exists.
final class ProfileBadgeView: NSView {
    static let size: CGFloat = 16
    private let label = NSTextField(labelWithString: "")
    private var color: GroupColor?
    /// The profile's menu (right-click or click): the host's actions.
    var makeMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("cmux.browser.profileBadge")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ badge: BrowserProfileBadge) {
        color = badge.color
        label.stringValue = badge.monogram
        let help = BrowserProfileStrings.badgeHelp(badge.name)
        toolTip = help
        setAccessibilityLabel(help)
        needsDisplay = true
        updateLayer()
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = (color?.fill ?? Palette.hoverFill).cgColor
            label.textColor = Palette.textSecondary
        }
    }
}
