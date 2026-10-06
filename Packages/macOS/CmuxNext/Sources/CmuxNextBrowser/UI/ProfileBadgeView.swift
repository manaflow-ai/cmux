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
    private let symbol = NSImageView()
    /// What the badge shows now (tests): an SF Symbol name, or text.
    private(set) var shownSymbol: String?
    var shownText: String { label.stringValue }
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
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        symbol.isHidden = true
        addSubview(label)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        // A profile icon is an emoji, a letter, or an SF Symbol name.
        if let image = Self.symbolImage(badge.monogram) {
            shownSymbol = badge.monogram
            symbol.image = image
            label.stringValue = ""
        } else {
            shownSymbol = nil
            symbol.image = nil
            label.stringValue = badge.monogram
        }
        symbol.isHidden = shownSymbol == nil
        let help = BrowserProfileStrings.badgeHelp(badge.name)
        toolTip = help
        setAccessibilityLabel(help)
        needsDisplay = true
        updateLayer()
    }

    /// The symbol for `name` when it is an SF Symbol name (lowercase
    /// letters, digits and dots, more than one character).
    static func symbolImage(_ name: String) -> NSImage? {
        guard name.count > 1, name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }) else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
            symbol.contentTintColor = Palette.textSecondary
        }
    }
}
