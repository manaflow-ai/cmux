import AppKit
import CmuxHomeCore

/// The conversation header over the transcript: one flat bar in the page
/// colour with the other participant's avatar (a true circle) beside the
/// name. Rows scroll under it (`HomeController.topInset`) and end at its
/// edge; it draws no border, glass or pill, so it reads as part of the page
/// rather than a strip laid over it. The Chief's avatar is a glyph on the
/// theme highlight (its ANSI blue), not a letter; other participants show their initials.
/// The name opens nothing, so it is plain text, not a button.
final class HomeGlassHeaderView: NSView {
    /// The opaque page-coloured fill (rows under it never show through).
    let backdrop = NSView()
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.wantsLayer = true
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
    /// page fill, the name and initials in `text`, and the Chief's glyph in
    /// `accent` on a faint disc of it (a person's disc is `disc`).
    func applyColors(disc: NSColor, text: NSColor, page: NSColor, accent: NSColor) { // theme-scoped
        backdrop.layer?.backgroundColor = page.withAlphaComponent(1).cgColor
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
        let s = Self.avatarSize
        let nameWidth = min(ceil(name.intrinsicContentSize.width), max(0, bounds.width - 32 - s - Self.avatarGap))
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
