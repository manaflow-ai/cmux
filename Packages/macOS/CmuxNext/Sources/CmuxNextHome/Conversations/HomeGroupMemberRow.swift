import AppKit
import CmuxHomeCore
import CmuxNextDesign

/// One member row of the group info sheet: a monogram avatar, the name with its tags, and Remove.
/// A value snapshot plus a closure (no model below the list).
final class HomeGroupMemberRow: NSView {
    let member: HomeGroupMember
    /// Remove; nil hides the button (me, a DM, or while an action runs).
    private let onRemove: (@MainActor () -> Void)?

    init(member: HomeGroupMember, colors: HomeGroupInfoColors, onRemove: (@MainActor () -> Void)?) {
        self.member = member
        self.onRemove = onRemove
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: member.name.isEmpty ? HomeConversationStrings.untitled : member.name)
        name.font = Typography.body
        name.textColor = colors.primary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [HomeGroupAvatar(initials: member.initials, isAgent: member.isAgent, colors: colors), name]
        for tag in Self.tags(member) {
            let label = NSTextField(labelWithString: tag)
            label.font = Typography.caption
            label.textColor = colors.secondary
            views.append(label)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if onRemove != nil {
            let remove = NSButton(title: HomeConversationStrings.infoRemove, target: self, action: #selector(removeClicked))
            remove.isBordered = false
            remove.attributedTitle = NSAttributedString(string: HomeConversationStrings.infoRemove,
                                                        attributes: [.font: Typography.caption, .foregroundColor: colors.danger])
            remove.setAccessibilityIdentifier("cmux.home.groupInfo.remove.\(member.id.rawValue)")
            views.append(remove)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.spacing = Metrics.space3
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.sidebarRowHeight + Metrics.space1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([name.stringValue] + Self.tags(member)).joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func tags(_ member: HomeGroupMember) -> [String] {
        var tags: [String] = []
        if member.isMe { tags.append(HomeConversationStrings.infoYou) }
        if let role = member.roleTag { tags.append(role) }
        if member.isAgent { tags.append(HomeConversationStrings.infoAgent) }
        if member.isInvited { tags.append(HomeConversationStrings.infoInvited) }
        return tags
    }

    @objc private func removeClicked() { onRemove?() }
}
