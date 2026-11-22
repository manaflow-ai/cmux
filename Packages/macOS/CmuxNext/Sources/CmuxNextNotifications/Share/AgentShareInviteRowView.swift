import AppKit
import CmuxNextDesign

/// One invited account in the Invite People sheet: its address, its role (and whether it is in the
/// chat now), and a quiet destructive Remove, never a filled red button (design chat-multiplayer.md
/// 2). Values and a closure only: no model reference below the list (cmux#2586).
final class AgentShareInviteRowView: NSView {
    static let height: CGFloat = 40

    let account: ThemedLabel
    let detail: ThemedLabel
    let removeButton: CmuxDialogButtonView
    private let onRemove: () -> Void

    init(account: String, detail: String, removeTitle: String, isRemoving: Bool, onRemove: @escaping () -> Void) {
        self.account = ThemedLabel(labelWithString: account)
        self.detail = ThemedLabel(labelWithString: detail)
        self.onRemove = onRemove
        removeButton = CmuxDialogButtonView(CmuxDialogButton(id: "remove", title: removeTitle, role: .destructive), hint: nil, quiet: true,
                                            target: nil, action: #selector(removePressed))
        super.init(frame: .zero)
        removeButton.target = self
        translatesAutoresizingMaskIntoConstraints = false
        self.account.font = Typography.body
        self.account.lineBreakMode = .byTruncatingMiddle
        self.account.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.detail.font = Typography.caption
        self.detail.ink = .secondary
        let text = NSStackView(views: [self.account, self.detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        removeButton.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.remove")
        removeButton.isEnabled = !isRemoving
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [text, NSView(), removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(account), \(detail)")
        identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    @objc func removePressed() { onRemove() }
}
