import AppKit
import CmuxHomeCore

/// The conversation header over the transcript: a Liquid Glass bar with the
/// other participant's monogram and a glass name pill, as Messages shows
/// it. Rows scroll under it (`HomeController.topInset`).
final class HomeGlassHeaderView: NSView {
    let glass = NSGlassEffectView()
    let avatar = NSTextField(labelWithString: "")
    private let avatarDisc = NSView()
    let name = NSButton(title: "", target: nil, action: nil)

    static let height: CGFloat = 80
    static let avatarSize: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        avatarDisc.wantsLayer = true
        avatarDisc.layer?.cornerRadius = Self.avatarSize / 2
        addSubview(avatarDisc)
        avatar.alignment = .center
        avatar.font = .systemFont(ofSize: 16, weight: .semibold)
        addSubview(avatar)
        name.bezelStyle = .glass
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ summary: ConversationSummary?, me: ParticipantID) {
        let title = summary?.displayTitle(me: me) ?? ""
        name.title = title
        avatar.stringValue = summary?.participants.first { $0.id != me }?.initials ?? ""
        setAccessibilityLabel(title)
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(disc: NSColor, text: NSColor) { // theme-scoped
        avatarDisc.layer?.backgroundColor = disc.cgColor
        avatar.textColor = text
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let s = Self.avatarSize
        let disc = CGRect(x: (bounds.width - s) / 2, y: 6, width: s, height: s)
        avatarDisc.frame = disc
        let textHeight: CGFloat = 20
        avatar.frame = CGRect(x: disc.minX, y: disc.midY - textHeight / 2, width: s, height: textHeight)
        name.sizeToFit()
        let w = min(bounds.width - 32, name.frame.width + 16)
        name.frame = CGRect(x: (bounds.width - w) / 2, y: disc.maxY + 4, width: w, height: 26)
    }
}
