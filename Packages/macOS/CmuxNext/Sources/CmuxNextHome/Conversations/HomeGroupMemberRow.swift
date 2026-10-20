import CmuxHomeCore
import CmuxNextDesign
import SwiftUI

/// One member row of the group info sheet: a monogram avatar, the name with its tags, and Remove.
/// A value snapshot plus a closure (no model below the list).
struct HomeGroupMemberRow: View {
    let member: HomeGroupMember
    let colors: HomeGroupInfoColors
    /// Remove; nil hides the button (me, a DM, or while an action runs).
    let onRemove: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: Metrics.space3) {
            HomeGroupAvatar(initials: member.initials, isAgent: member.isAgent, colors: colors)
            Text(member.name.isEmpty ? HomeConversationStrings.untitled : member.name)
                .font(Font(Typography.body))
                .foregroundStyle(colors.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
            }
            Spacer(minLength: Metrics.space2)
            if let onRemove {
                Button(HomeConversationStrings.infoRemove) { onRemove() }
                    .buttonStyle(.plain)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.danger)
                    .accessibilityIdentifier("cmux.home.groupInfo.remove.\(member.id.rawValue)")
            }
        }
        .frame(height: Metrics.sidebarRowHeight + Metrics.space1)
        .accessibilityElement(children: .combine)
    }

    private var tags: [String] {
        var tags: [String] = []
        if member.isMe { tags.append(HomeConversationStrings.infoYou) }
        if member.isAgent { tags.append(HomeConversationStrings.infoAgent) }
        if member.isInvited { tags.append(HomeConversationStrings.infoInvited) }
        return tags
    }
}
