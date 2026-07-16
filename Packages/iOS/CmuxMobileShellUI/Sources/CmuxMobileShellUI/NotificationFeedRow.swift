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
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            details.append(subtitle)
        }
        if !item.body.isEmpty {
            details.append(item.body)
        }
        details.append(workspaceName)
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
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(item.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if item.isRead {
                        Circle().stroke(Color.clear, lineWidth: 1)
                    }
                }
                .padding(.top, 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.title)
                        .font(.headline)
                        .fontWeight(item.isRead ? .medium : .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(item.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NotificationFeedMetadata(item: item)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }
}

private struct NotificationFeedMetadata: View {
    let item: MobileNotificationFeedItem

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                workspaceLabel
                separator
                macLabel
            }
            VStack(alignment: .leading, spacing: 3) {
                workspaceLabel
                macLabel
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var workspaceLabel: some View {
        Label(workspaceContext, systemImage: "rectangle.stack")
            .lineLimit(1)
    }

    private var macLabel: some View {
        Label(macStatusText, systemImage: macStatusImage)
            .foregroundStyle(item.connectionStatus == .connected ? Color.secondary : Color.orange)
            .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: "•").accessibilityHidden(true)
    }

    private var workspaceName: String {
        guard let title = item.workspaceTitle, !title.isEmpty else {
            return L10n.string("mobile.notificationFeed.workspaceFallback", defaultValue: "Workspace")
        }
        return title
    }

    private var workspaceContext: String {
        guard let surfaceTitle = item.surfaceTitle, !surfaceTitle.isEmpty else {
            return workspaceName
        }
        return String(
            format: L10n.string(
                "mobile.notificationFeed.workspaceSurfaceFormat",
                defaultValue: "%1$@ / %2$@"
            ),
            workspaceName,
            surfaceTitle
        )
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

    private var macStatusImage: String {
        switch item.connectionStatus {
        case .connected: "desktopcomputer"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .unavailable: "wifi.slash"
        }
    }
}
#endif
