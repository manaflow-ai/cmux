import AppKit
import CmuxNextDesign

/// One chat on one line: a checkbox, the chat's title, then its project,
/// agent, prompt count and age. Clicking anywhere on the row toggles it,
/// over the shared hover and pressed fill (`ChromeHover`); the keyboard
/// cursor shows as its focus ring.
final class ChatRow: NSView {
    static let height: CGFloat = 26
    private let toggle: () -> Void
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private(set) lazy var hover = ChromeHover(self, outset: NSSize(width: 6, height: 0), tracking: .activeInKeyWindow)

    init(chat: AgentChat, now: Date, toggle: @escaping () -> Void) {
        self.toggle = toggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = chat.title.isEmpty ? OnboardingStrings.chatsUntitled : chat.title
        let name = OnboardingLabel.make(title)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = OnboardingLabel.make(Self.detail(chat, now: now), font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        box.target = self
        box.action = #selector(boxPressed)
        box.setAccessibilityLabel(title)
        for view in [box, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), box.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 8), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "cmux · Claude Code · Prompts: 12 · 2 days ago".
    static func detail(_ chat: AgentChat, now: Date) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: chat.lastActive, relativeTo: now)
        return [chat.folder.lastPathComponent, chat.app.displayName, OnboardingStrings.chatsPrompts(chat.prompts), when]
            .joined(separator: " · ")
    }

    @objc private func boxPressed() { toggle() }

    func update(checked: Bool, cursor: Bool) {
        box.state = checked ? .on : .off
        hover.state.focused = cursor
    }

    override func layout() {
        super.layout()
        hover.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hover.state.hovering = true }
    override func mouseExited(with event: NSEvent) { hover.state.hovering = false }
    override func mouseDown(with event: NSEvent) { hover.state.pressed = true }

    /// Toggles on release inside the row, as a button does.
    override func mouseUp(with event: NSEvent) {
        guard hover.state.pressed else { return }
        hover.state.pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
    }
}
