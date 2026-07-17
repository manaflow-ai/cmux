#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedRow: View {
    let item: MobileNotificationFeedItem
    let actions: NotificationFeedActions

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            NotificationFeedRowLabel(item: item)
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: {
            Button {
                actions.open(item)
            } label: {
                Label(
                    L10n.string("mobile.notificationFeed.open", defaultValue: "Open"),
                    systemImage: "arrow.up.forward.app"
                )
            }
            .accessibilityIdentifier("MobileNotificationFeedOpenMenu-\(accessibilitySuffix)")

            if !item.isRead {
                Button {
                    actions.markRead(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read"),
                        systemImage: "envelope.open"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedMarkReadMenu-\(accessibilitySuffix)")
            } else {
                Button {
                    actions.markUnread(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread"),
                        systemImage: "envelope.badge"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedMarkUnreadMenu-\(accessibilitySuffix)")
            }
        })
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !item.isRead {
                Button {
                    actions.markRead(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read"),
                        systemImage: "envelope.open"
                    )
                }
                .tint(.blue)
                .accessibilityIdentifier("MobileNotificationFeedMarkReadSwipe-\(accessibilitySuffix)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.string(
            "mobile.notificationFeed.openHint",
            defaultValue: "Opens the workspace and terminal for this notification."
        ))
        .accessibilityActions {
            Button(L10n.string("mobile.notificationFeed.open", defaultValue: "Open")) {
                actions.open(item)
            }
            if !item.isRead {
                Button(L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read")) {
                    actions.markRead(item)
                }
            } else {
                Button(L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread")) {
                    actions.markUnread(item)
                }
            }
        }
        .accessibilityIdentifier("MobileNotificationFeedRow-\(accessibilitySuffix)")
    }

    private var accessibilitySuffix: String {
        "\(item.macDeviceID)-\(item.notificationID)"
    }

    private var accessibilityValue: String {
        var details = [
            item.isRead
                ? L10n.string("mobile.notificationFeed.read", defaultValue: "Read")
                : L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread"),
        ]
        details.append(workspaceName)
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            details.append(subtitle)
        }
        if !item.body.isEmpty {
            details.append(item.body)
        }
        if let surfaceTitle = item.surfaceTitle, !surfaceTitle.isEmpty {
            details.append(surfaceTitle)
        }
        details.append(item.macDisplayName)
        details.append(item.createdAt.formatted(.relative(presentation: .named)))
        return details.formatted()
    }

    private var workspaceName: String {
        guard let title = item.workspaceTitle, !title.isEmpty else {
            return L10n.string("mobile.notificationFeed.workspaceFallback", defaultValue: "Workspace")
        }
        return title
    }
}

private struct NotificationFeedRowLabel: View {
    let item: MobileNotificationFeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.isRead ? Color.clear : Color.accentColor)
                .frame(width: 6, height: 6)
                .overlay {
                    if item.isRead {
                        Circle().stroke(Color.clear, lineWidth: 1)
                    }
                }
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(item.isRead ? .medium : .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(item.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                NotificationFeedContextLine(
                    workspaceTitle: item.workspaceTitle,
                    subtitle: item.subtitle
                )

                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NotificationFeedMetadata(item: item)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }
}

private struct NotificationFeedContextLine: View {
    let workspaceTitle: String?
    let subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(workspaceName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: "•")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var workspaceName: String {
        guard let workspaceTitle, !workspaceTitle.isEmpty else {
            return L10n.string("mobile.notificationFeed.workspaceFallback", defaultValue: "Workspace")
        }
        return workspaceTitle
    }
}

private struct NotificationFeedMetadata: View {
    let item: MobileNotificationFeedItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let surfaceName {
                Text(surfaceName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                separator
            }
            Text(macStatusText)
                .foregroundStyle(item.connectionStatus == .connected ? Color.secondary : Color.orange)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var separator: some View {
        Text(verbatim: "•")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var surfaceName: String? {
        guard let surfaceTitle = item.surfaceTitle, !surfaceTitle.isEmpty else {
            return nil
        }
        return surfaceTitle
    }

    private var macStatusText: String {
        switch item.connectionStatus {
        case .connected:
            return item.macDisplayName
        case .reconnecting:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macReconnectingFormat",
                    defaultValue: "%@ · Reconnecting"
                ),
                item.macDisplayName
            )
        case .unavailable:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macUnavailableFormat",
                    defaultValue: "%@ · Unavailable"
                ),
                item.macDisplayName
            )
        }
    }
}
#endif
