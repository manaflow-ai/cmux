import AppKit

/// The floating "jump to latest" pill shown when the user scrolls away from new output.
@MainActor
final class AcpmuxJumpToLatestPill: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        setAccessibilityIdentifier("acpmuxChat.jumpToLatest")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(unread: Int, theme: AcpmuxChatTheme) {
        let title = unread > 0
            ? String.localizedStringWithFormat(
                String(localized: "acpmuxChat.jump.unread", defaultValue: "%lld new messages"),
                Int64(unread)
            )
            : String(localized: "acpmuxChat.jump.latest", defaultValue: "Jump to latest")
        attributedTitle = NSAttributedString(string: "\u{2193}  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: theme.userText,
        ])
        layer?.backgroundColor = theme.accent.cgColor
        sizeToFit()
        frame.size = CGSize(width: frame.width + 24, height: 26)
    }
}
