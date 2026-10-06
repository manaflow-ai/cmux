import AppKit
import CmuxHomeCore

/// The conversation header over the transcript: a Liquid Glass bar with the
/// other participant's monogram and a glass name pill, as Messages shows
/// it. Rows scroll under it (`HomeController.topInset`); the glass carries a
/// veil of the page colour so they never show through as blurred text.
/// The pill opens nothing, so it is text on glass, not a button (a button
/// dims like a disabled control when the window is not key).
final class HomeGlassHeaderView: NSView {
    let glass = NSGlassEffectView()
    let avatar = NSTextField(labelWithString: "")
    private let avatarDisc = NSView()
    let namePill = NSGlassEffectView()
    /// The pill's content: the title, centred vertically in `layout()`
    /// (the glass sizes its content view to the pill).
    private let nameHolder = NSView()
    let name = NSTextField(labelWithString: "")

    static let height: CGFloat = 80
    static let avatarSize: CGFloat = 40
    /// The veil's opacity over the glass: rows under it read as a soft wash.
    static let veilAlpha: CGFloat = 0.82

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        avatarDisc.wantsLayer = true
        avatarDisc.layer?.cornerRadius = Self.avatarSize / 2
        addSubview(avatarDisc)
        avatar.alignment = .center
        avatar.font = .systemFont(ofSize: 16, weight: .semibold)
        addSubview(avatar)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        namePill.cornerRadius = 13
        nameHolder.addSubview(name)
        namePill.contentView = nameHolder
        addSubview(namePill)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ summary: ConversationSummary?, me: ParticipantID) {
        let title = summary?.displayTitle(me: me) ?? ""
        name.stringValue = title
        avatar.stringValue = summary?.participants.first { $0.id != me }?.initials ?? ""
        setAccessibilityLabel(title)
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(disc: NSColor, text: NSColor, page: NSColor) { // theme-scoped
        avatarDisc.layer?.backgroundColor = disc.cgColor
        avatar.textColor = text
        name.textColor = text
        glass.tintColor = page.withAlphaComponent(Self.veilAlpha)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let s = Self.avatarSize
        let disc = CGRect(x: (bounds.width - s) / 2, y: 6, width: s, height: s)
        avatarDisc.frame = disc
        let textHeight: CGFloat = 20
        avatar.frame = CGRect(x: disc.minX, y: disc.midY - textHeight / 2, width: s, height: textHeight)
        let w = min(bounds.width - 32, ceil(name.intrinsicContentSize.width) + 24)
        namePill.frame = CGRect(x: (bounds.width - w) / 2, y: disc.maxY + 4, width: w, height: 26)
        let titleHeight = ceil(name.intrinsicContentSize.height)
        name.frame = CGRect(x: 0, y: (26 - titleHeight) / 2, width: w, height: titleHeight)
    }
}
