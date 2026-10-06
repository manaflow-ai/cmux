import AppKit
import CmuxHomeCore

/// The conversation header over the transcript: the other participant's
/// avatar (a true circle) beside the name, on the page's own fill. Rows
/// scroll under it (`HomeController.topInset`) and end at its edge. Over a
/// see-through page (window backdrop art) the fill is a fade from the page
/// colour to clear instead, so no hard-edged bar sits on the art. It draws
/// no border, glass or pill, so it reads as part of the page rather than a
/// strip laid over it. The Chief's avatar is a glyph on the
/// theme highlight (its ANSI blue), not a letter; other participants show their initials.
/// The name opens nothing, so it is plain text, not a button.
final class HomeGlassHeaderView: NSView {
    /// The page-coloured fill: solid on an opaque page, else `fade`.
    let backdrop = NSView()
    /// Page colour at the top to clear at the bottom (see-through pages).
    let fade = CAGradientLayer()
    let avatar = NSTextField(labelWithString: "")
    /// The Chief's glyph, shown instead of the initials.
    let avatarGlyph = NSImageView()
    let avatarDisc = NSView()
    let name = NSTextField(labelWithString: "")
    /// The other participant is the Chief (the glyph avatar shows).
    private(set) var isChief = false
    /// The disc colours from the last `applyColors` (a kind change repaints).
    private var personDisc = NSColor.clear
    private var accentDisc = NSColor.clear

    static let height: CGFloat = 52
    static let avatarSize: CGFloat = 26
    static let avatarGap: CGFloat = 8
    static let chiefSymbol = "sparkle"
    /// The fade's opacity at the top edge over a see-through page.
    static let fadeTopAlpha: CGFloat = 0.85

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.wantsLayer = true
        // `backdrop` is not flipped: its layer's y = 1 is the top edge.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        backdrop.layer?.addSublayer(fade)
        addSubview(backdrop)
        avatarDisc.wantsLayer = true
        avatarDisc.layer?.cornerRadius = Self.avatarSize / 2
        addSubview(avatarDisc)
        avatar.alignment = .center
        avatar.font = .systemFont(ofSize: 11, weight: .semibold)
        addSubview(avatar)
        avatarGlyph.image = NSImage(systemSymbolName: Self.chiefSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        avatarGlyph.imageScaling = .scaleProportionallyDown
        avatarGlyph.isHidden = true
        addSubview(avatarGlyph)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ summary: ConversationSummary?, me: ParticipantID) {
        let title = summary?.displayTitle(me: me) ?? ""
        name.stringValue = title
        avatar.stringValue = summary?.participants.first { $0.id != me }?.initials ?? ""
        isChief = summary?.kind(me: me) == .chief
        avatar.isHidden = isChief
        avatarGlyph.isHidden = !isChief
        paintDisc()
        setAccessibilityLabel(title)
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`): the
    /// page fill (a fade of it when the page is `seeThrough`), the name and
    /// initials in `text`, and the Chief's glyph in `accent` on a faint disc
    /// of it (a person's disc is `disc`).
    func applyColors(disc: NSColor, text: NSColor, page: NSColor, seeThrough: Bool, accent: NSColor) { // theme-scoped
        let solid = page.withAlphaComponent(1)
        backdrop.layer?.backgroundColor = seeThrough ? nil : solid.cgColor
        fade.isHidden = !seeThrough
        fade.colors = [solid.withAlphaComponent(Self.fadeTopAlpha).cgColor, solid.withAlphaComponent(0).cgColor]
        personDisc = disc
        accentDisc = accent.withAlphaComponent(0.2)
        paintDisc()
        avatarGlyph.contentTintColor = accent
        avatar.textColor = text
        name.textColor = text
    }

    private func paintDisc() {
        avatarDisc.layer?.backgroundColor = (isChief ? accentDisc : personDisc).cgColor
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = backdrop.bounds
        CATransaction.commit()
        let s = Self.avatarSize
        // Measured from the text: a truncating label reports no intrinsic width.
        let textWidth = ceil(name.attributedStringValue.size().width) + 4
        let nameWidth = min(textWidth, max(0, bounds.width - 32 - s - Self.avatarGap))
        let rowWidth = s + (nameWidth > 0 ? Self.avatarGap + nameWidth : 0)
        let disc = CGRect(x: ((bounds.width - rowWidth) / 2).rounded(), y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
        avatarDisc.frame = disc
        let initialsHeight = ceil(avatar.intrinsicContentSize.height)
        avatar.frame = CGRect(x: disc.minX, y: disc.midY - initialsHeight / 2, width: s, height: initialsHeight)
        avatarGlyph.frame = disc.insetBy(dx: 5, dy: 5)
        let titleHeight = ceil(name.intrinsicContentSize.height)
        name.frame = CGRect(x: disc.maxX + Self.avatarGap, y: (disc.midY - titleHeight / 2).rounded(), width: nameWidth, height: titleHeight)
    }
}
