public import AppKit
public import CmuxNextDesign

/// How the browser toolbar's profile button shows a tab's browser profile: its
/// icon or first letter on its color (plans/cmux-next/data-model.md section 5).
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

extension BrowserProfileBadge {
    /// The avatar as an image of side `side` (the profile menu's header row): the disc in the profile's
    /// color, its letter or symbol on it, drawn for the appearance it is shown in.
    @MainActor public func avatarImage(side: CGFloat) -> NSImage {
        let badge = self
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (badge.color?.fill ?? Palette.hoverFill).setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let symbol = ProfileBadgeView.symbolImage(badge.monogram)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)) {
                let size = symbol.size
                let tinted = NSImage(size: size, flipped: false) { box in
                    symbol.draw(in: box)
                    Palette.textSecondary.set()
                    box.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                let text = NSAttributedString(string: badge.monogram, attributes: [
                    .font: NSFont.systemFont(ofSize: side * 0.55, weight: .semibold), .foregroundColor: Palette.textSecondary,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            return true
        }
    }
}

/// The round avatar the toolbar's profile button draws in place of its glyph: the tab's
/// browser profile, at the toolbar's right, outside the address bar (Leo 2026-11-22, "move it
/// outside the omnibar"). It only draws: the button under it takes the press, the tooltip and
/// the accessibility label.
final class ProfileBadgeView: NSView {
    /// The disc's side beside toolbar glyphs whose box is `glyph` wide: 4 pt past their ink (a filled
    /// disc reads smaller than a glyph of the same side), 20 pt at Standard; never past `limit`.
    static func side(forGlyph glyph: CGFloat, limit: CGFloat) -> CGFloat {
        min((glyph * DensityTokens.toolbarGlyphInkRatio + 4).rounded(), limit)
    }
    private(set) var side: CGFloat
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: side)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: side)
    private let label = ChromeLabel(labelWithString: "")
    private let symbol = NSImageView()
    /// What the badge shows now (tests): an SF Symbol name, or text.
    private(set) var shownSymbol: String?
    var shownText: String { label.stringValue }
    private var color: GroupColor?
    /// The profile shown now.
    private(set) var badge: BrowserProfileBadge?

    init(side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = side / 2
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        symbol.isHidden = true
        addSubview(label)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            heightConstraint,
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    /// Another density or screen: the disc follows the toolbar's glyph size.
    func setSide(_ next: CGFloat) {
        guard next != side else { return }
        side = next
        widthConstraint.constant = next
        heightConstraint.constant = next
        layer?.cornerRadius = next / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The press belongs to the button under the disc.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ badge: BrowserProfileBadge) {
        self.badge = badge
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
        needsDisplay = true
        updateLayer()
    }

    /// The symbol for `name` when it is an SF Symbol name (lowercase
    /// letters, digits and dots, more than one character).
    static func symbolImage(_ name: String) -> NSImage? {
        guard name.count > 1, name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }) else { return nil }
        // chrome-icons: allow the profile's own symbol, chosen by the user
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
