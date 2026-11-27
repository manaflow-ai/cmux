public import AppKit
public import CmuxNextDesign
import CmuxNextIcons

/// How the browser toolbar's profile button shows a tab's browser profile: its
/// icon or first letter on its color (plans/cmux-next/data-model.md section 5).
public struct BrowserProfileBadge: Hashable, Sendable {
    public var monogram: String
    public var color: GroupColor?
    /// The profile's name, for the tooltip and VoiceOver.
    public var name: String
    /// An incognito tab's disc (cmuxterm-hq RFD 0125, D1: "incognito (dark disc, incognito glyph)"): the incognito
    /// glyph on the primary-text plate, never the plain person glyph; `monogram` and `color` are unused.
    public var isIncognito: Bool

    public init(monogram: String, color: GroupColor?, name: String, isIncognito: Bool = false) {
        self.monogram = monogram
        self.color = color
        self.name = name
        self.isIncognito = isIncognito
    }

    /// An incognito tab's disc, named `name` (the window's "Incognito").
    public static func incognito(name: String) -> BrowserProfileBadge {
        BrowserProfileBadge(monogram: "", color: nil, name: name, isIncognito: true)
    }

    /// The disc's fill and its glyph's ink: the profile's color under the secondary text, or for incognito the primary
    /// text's plate under the ink drawn on it (dark on a light theme, as Chrome's incognito avatar; light on a dark one,
    /// where a dark disc would vanish into the bar). Read inside the theme being drawn.
    @MainActor var plate: NSColor { isIncognito ? Palette.textPrimary : color?.fill ?? Palette.hoverFill }
}

extension BrowserProfileBadge {
    /// The avatar as an image of side `side` (the profile menu's header row): the disc in the profile's
    /// color, its letter or symbol on it, drawn for the appearance it is shown in. Drawn at the size it is shown,
    /// so the profile menu's card draws it larger with its letter in proportion (`letterSize`).
    @MainActor public func avatarImage(side: CGFloat) -> NSImage {
        let fill = plate, ink = isIncognito ? Palette.textOnPrimary : Palette.textSecondary
        let monogram = monogram, caption = TypeScale.caption
        // chrome-icons: allow the incognito disc wears the window's own incognito mark (IncognitoBadgeView); Chromium's pin has none
        let glyph: NSImage? = isIncognito ? NSImage.icon(.browserIncognito, size: Self.letterSize(side: side, least: caption) + 2) : ProfileBadgeView.symbolImage(monogram)
        let incognito = isIncognito
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = Self.letterSize(side: rect.height, least: caption)
            let symbol = incognito ? glyph.map { Self.inked($0, ink) }
                : glyph?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [ink])))
            let text = NSAttributedString(string: monogram, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: ink])
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let box = symbol?.size ?? text.size()
            let frame = NSRect(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2, width: box.width, height: box.height)
            if let symbol { symbol.draw(in: frame) } else { text.draw(at: frame.origin) }
            return true
        }
    }

    /// The letter's size on a disc of side `side`: `least` (the toolbar's caption) on the button's and the menu
    /// row's small discs, about 2/5 of a larger one (the profile menu's card).
    /// Template `image` filled with `ink` (the pack's icons are templates, which a drawing handler does not tint).
    nonisolated static func inked(_ image: NSImage, _ ink: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    nonisolated static func letterSize(side: CGFloat, least: CGFloat) -> CGFloat { max(least, (side * 0.42).rounded()) }
}

extension BrowserProfileBadge {
    /// The avatar of `record`, as the toolbar button draws it.
    public init(_ record: BrowserProfileRecord) {
        self.init(monogram: record.monogram, color: record.color.flatMap(GroupColor.init(rawValue:)), name: record.name)
    }

    /// Each profile's small avatar by its id: the profile menu's rows draw them, as Chrome's and Helium's other-profile
    /// rows do.
    @MainActor public static func menuImages(_ records: [BrowserProfileRecord]) -> [String: NSImage] {
        Dictionary(records.map { ($0.id, BrowserProfileBadge($0).avatarImage(side: 16)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The profile menu's first row for a tab with this profile: its name, why the tab has it (`source`; for an
    /// incognito tab, when its data goes) and its avatar.
    @MainActor public func menuHeader(_ source: BrowserProfileCascade.Source) -> (title: String, subtitle: String?, image: NSImage?) {
        (name, isIncognito ? BrowserProfileStrings.incognitoReason : BrowserProfileStrings.reason(source), avatarImage(side: 20))
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
        label.font = .systemFont(ofSize: TypeScale.caption, weight: .semibold)
        label.alignment = .center
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: TypeScale.caption, weight: .semibold)
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
        if badge.isIncognito {
            shownSymbol = IconName.browserIncognito.rawValue
            symbol.image = NSImage.icon(.browserIncognito, size: TypeScale.caption + 2) // chrome-icons: allow the window's incognito mark, as above
            label.stringValue = ""
        } else if let image = Self.symbolImage(badge.monogram) {
            // A profile icon is an emoji, a letter, or an SF Symbol name.
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
            let plate = badge?.plate ?? color?.fill ?? Palette.hoverFill
            layer?.backgroundColor = plate.cgColor
            // The bar's ink on this plate over every ground the bar shows (`OmnibarInk`), not the theme's secondary
            // text, which a color plate or the bar's lift could take under 4.5:1 (issue 50986). Incognito's plate is
            // the primary text, so its glyph takes the ink made for that plate.
            let ink = badge?.isIncognito == true ? Palette.textOnPrimary : OmnibarStyle.ink.iconColor(on: [plate], bare: false)
            label.textColor = ink
            symbol.contentTintColor = ink
        }
    }

    /// A theme repaint skips a badge outside a window: entering one redraws it in the shown theme's ink.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsDisplay = true }
    }

    /// The label's color now (tests).
    var shownTextColor: NSColor? { label.textColor }
}
