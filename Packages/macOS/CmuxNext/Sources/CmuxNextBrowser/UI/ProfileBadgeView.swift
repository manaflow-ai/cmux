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
    private let label = ChromeLabel(labelWithString: "")
    private let symbol = NSImageView()
    /// What the badge shows now (tests): an SF Symbol name, or text.
    private(set) var shownSymbol: String?
    var shownText: String { label.stringValue }
    private var color: GroupColor?
    /// The badge shown now.
    private var shown: BrowserProfileBadge?
    /// The profile's menu (right-click or click): the host's actions.
    var makeMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = Self.size / 2
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.alignment = .center
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        symbol.isHidden = true
        addSubview(label)
        addSubview(symbol)
        // The omnibar's badge row keeps the badge at its size, as a fixed one.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("cmux.browser.profileBadge")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The badge takes the whole press (not its image or label) and the first
    /// one in a browser window that is not key: one click acts, as Chrome's
    /// omnibar buttons do (user, 2026-10-28, "click the star twice").
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ badge: BrowserProfileBadge) {
        // The chrome shows the tab's badge on every mount and profile list change, most with the same badge.
        guard badge != shown else { return }
        shown = badge
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
        needsLayout = true // invalidate: another badge (the guard above) centers another monogram or symbol
        let help = BrowserProfileStrings.badgeHelp(badge.name)
        themedToolTip = help
        setAccessibilityLabel(help)
        needsDisplay = true // invalidate: another badge (the guard above)
        updateLayer()
    }

    /// The symbol for `name` when it is an SF Symbol name (lowercase
    /// letters, digits and dots, more than one character).
    static func symbolImage(_ name: String) -> NSImage? {
        guard name.count > 1, name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }) else { return nil }
        // chrome-icons: allow the profile's own symbol, chosen by the user
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: Frame layout

    /// A round badge of `size`, whatever it shows.
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) centers the content again
    }

    /// The monogram and the symbol centered in the badge, each at its own size.
    override func layout() {
        super.layout()
        for view in [label, symbol] as [NSView] {
            view.setAlignmentFrame(Self.centered(view.intrinsicContentSize, in: bounds))
        }
    }

    /// `size` centered in `bounds`, on whole points; a view with no intrinsic size (an empty symbol) gets none.
    nonisolated static func centered(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let width = max(0, size.width), height = max(0, size.height)
        return CGRect(x: (bounds.midX - width / 2).rounded(), y: (bounds.midY - height / 2).rounded(), width: width, height: height)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return super.mouseDown(with: event) }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: self, gap: 4), in: self)
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = (color?.fill ?? Palette.hoverFill).cgColor
            label.textColor = Palette.textSecondary
            symbol.contentTintColor = Palette.textSecondary
        }
    }
}
