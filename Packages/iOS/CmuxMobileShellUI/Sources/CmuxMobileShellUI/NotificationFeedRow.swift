import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

/// One value-only notification row with workspace identity and read-state actions.
struct NotificationFeedRow: View {
    let item: MobileNotificationFeedItem
    let timeLabel: String
    let actions: NotificationFeedRowActions

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            WorkspaceUnreadDot(isUnread: !item.isRead, leftShift: 0)
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspaceDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                titleLine
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.open)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: actions.toggleRead) {
                Label(toggleReadLabel, systemImage: item.isRead ? "envelope.badge.fill" : "envelope.open.fill")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: actions.remove) {
                Label(
                    L10n.string("mobile.notifications.remove", defaultValue: "Remove"),
                    systemImage: "trash.fill"
                )
            }
            .tint(.red)
        }
        .contextMenu {
            Button(action: actions.open) {
                Label(
                    L10n.string("mobile.notifications.openWorkspace", defaultValue: "Open Workspace"),
                    systemImage: "arrow.up.forward.app"
                )
            }
            Button(action: actions.toggleRead) {
                Label(toggleReadLabel, systemImage: item.isRead ? "envelope.badge.fill" : "envelope.open.fill")
            }
            Button(role: .destructive, action: actions.remove) {
                Label(
                    L10n.string("mobile.notifications.remove", defaultValue: "Remove"),
                    systemImage: "trash.fill"
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("MobileNotificationRow-\(item.id.uuidString.lowercased())")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(actions.open)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: 36, height: 36)
            Image(systemName: item.workspaceName == nil ? "bell.fill" : "terminal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }

    private var avatarGradient: LinearGradient {
        if item.workspaceName == nil {
            return LinearGradient(
                colors: [Color.secondary.opacity(0.8), Color.gray],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return MachineAvatarColors.gradient(
            machineID: item.workspaceID.uuidString,
            fallbackID: item.workspaceID.uuidString
        )
    }

    private var workspaceDisplayName: String {
        item.workspaceName ?? L10n.string(
            "mobile.notifications.missingWorkspace",
            defaultValue: "Deleted Workspace"
        )
    }

    private var titleLine: Text {
        let title = Text(item.title)
            .font(.subheadline)
            .fontWeight(item.isRead ? .regular : .semibold)
            .foregroundColor(.primary)
        guard !item.subtitle.isEmpty else { return title }
        return title + Text(" · \(item.subtitle)")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }

    private var toggleReadLabel: String {
        item.isRead
            ? L10n.string("mobile.notifications.markUnread", defaultValue: "Mark Unread")
            : L10n.string("mobile.notifications.markRead", defaultValue: "Mark Read")
    }

    private var accessibilityLabel: String {
        var parts = [workspaceDisplayName, item.title]
        if !item.body.isEmpty { parts.append(item.body) }
        parts.append(timeLabel)
        if !item.isRead {
            parts.append(L10n.string("mobile.notifications.unread", defaultValue: "Unread"))
        }
        return parts.joined(separator: ", ")
    }
}
