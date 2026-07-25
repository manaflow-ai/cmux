#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedRow: View, Equatable {
    let item: MobileNotificationFeedItem
    let actions: NotificationFeedActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        let presentation = NotificationFeedRowPresentation(item: item)

        Button {
            actions.open(item)
        } label: {
            NotificationFeedRowLabel(
                title: item.title,
                createdAt: item.createdAt,
                isRead: item.isRead,
                presentation: presentation
            )
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
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
            } else {
                Button {
                    actions.markUnread(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread"),
                        systemImage: "envelope.badge"
                    )
                }
                .tint(.blue)
                .accessibilityIdentifier("MobileNotificationFeedMarkUnreadSwipe-\(accessibilitySuffix)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue(presentation: presentation))
        .accessibilityHint(L10n.string(
            "mobile.notificationFeed.openHint",
            defaultValue: "Opens this notification's workspace."
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

    private func accessibilityValue(presentation: NotificationFeedRowPresentation) -> String {
        var details = [
            item.isRead
                ? L10n.string("mobile.notificationFeed.read", defaultValue: "Read")
                : L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread"),
        ]
        details.append(accessibilityField(
            label: L10n.string("mobile.notificationFeed.row.workspace", defaultValue: "Workspace"),
            value: presentation.workspaceName
        ))
        if let contentPreview = presentation.contentPreview {
            details.append(contentPreview)
        }
        details.append(accessibilityField(
            label: L10n.string("mobile.notificationFeed.row.computer", defaultValue: "Computer"),
            value: presentation.computerStatusText
        ))
        details.append(item.createdAt.formatted(.relative(presentation: .named)))
        return details.formatted()
    }

    private func accessibilityField(label: String, value: String) -> String {
        String(
            format: L10n.string(
                "mobile.notificationFeed.row.fieldFormat",
                defaultValue: "%1$@: %2$@"
            ),
            label,
            value
        )
    }
}

private struct NotificationFeedRowLabel: View {
    let title: String
    let createdAt: Date
    let isRead: Bool
    let presentation: NotificationFeedRowPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NotificationFeedUnreadIndicator(isRead: isRead)

            VStack(alignment: .leading, spacing: 4) {
                NotificationFeedHeadline(
                    title: title,
                    createdAt: createdAt,
                    isRead: isRead,
                    representsWorkspace: presentation.workspaceMatchesTitle
                )

                NotificationFeedProvenance(
                    workspaceName: presentation.workspaceName,
                    workspaceMatchesTitle: presentation.workspaceMatchesTitle,
                    computerName: presentation.computerName,
                    computerIsReachable: presentation.connectionStatus == .connected
                )

                if let contentPreview = presentation.contentPreview {
                    NotificationFeedContentPreview(text: contentPreview)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }
}

private struct NotificationFeedUnreadIndicator: View {
    let isRead: Bool

    var body: some View {
        Circle()
            .fill(isRead ? Color.clear : Color.accentColor)
            .frame(width: 6, height: 6)
            .overlay {
                if isRead {
                    Circle().stroke(Color.clear, lineWidth: 1)
                }
            }
            .padding(.top, 5)
            .accessibilityHidden(true)
    }
}

private struct NotificationFeedHeadline: View {
    let title: String
    let createdAt: Date
    let isRead: Bool
    let representsWorkspace: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if representsWorkspace {
                    Image(systemName: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isRead ? .medium : .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A compact, immutable projection of the four facts a user scans before opening.
private struct NotificationFeedRowPresentation: Equatable {
    let workspaceName: String
    let workspaceMatchesTitle: Bool
    let contentPreview: String?
    let computerName: String
    let connectionStatus: MobileMacConnectionStatus

    init(item: MobileNotificationFeedItem) {
        let normalizedTitle = Self.normalized(item.title) ?? item.title
        let normalizedWorkspace = Self.normalized(item.workspaceTitle) ?? L10n.string(
            "mobile.notificationFeed.row.unknownWorkspace",
            defaultValue: "Unknown workspace"
        )
        let normalizedComputer = Self.normalized(item.macDisplayName) ?? item.macDeviceID

        workspaceName = normalizedWorkspace
        workspaceMatchesTitle = Self.matches(normalizedWorkspace, normalizedTitle)
        computerName = normalizedComputer
        connectionStatus = item.connectionStatus

        let redundantContent = [normalizedTitle, normalizedWorkspace, normalizedComputer]
        if let body = Self.normalized(item.body),
           !Self.matchesAny(body, redundantContent) {
            contentPreview = body
        } else if let subtitle = Self.normalized(item.subtitle),
                  !Self.matchesAny(subtitle, redundantContent) {
            // The desktop feed treats title + body as the primary content. The
            // optional subtitle becomes useful only when the body adds nothing.
            contentPreview = subtitle
        } else {
            contentPreview = nil
        }
    }

    var computerStatusText: String {
        applyingConnectionStatus(to: computerName)
    }

    private func applyingConnectionStatus(to value: String) -> String {
        switch connectionStatus {
        case .connected:
            return value
        case .reconnecting:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macReconnectingFormat",
                    defaultValue: "%@ · Reconnecting"
                ),
                value
            )
        case .unavailable:
            return String(
                format: L10n.string(
                    "mobile.notificationFeed.macUnavailableFormat",
                    defaultValue: "%@ · Unavailable"
                ),
                value
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func matchesAny(_ candidate: String, _ values: [String]) -> Bool {
        values.contains { matches(candidate, $0) }
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

private struct NotificationFeedProvenance: View {
    let workspaceName: String
    let workspaceMatchesTitle: Bool
    let computerName: String
    let computerIsReachable: Bool

    var body: some View {
        if workspaceMatchesTitle {
            NotificationFeedComputer(
                name: computerName,
                isReachable: computerIsReachable,
                allowsWrapping: false
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    NotificationFeedWorkspace(name: workspaceName, allowsWrapping: false)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    NotificationFeedComputer(
                        name: computerName,
                        isReachable: computerIsReachable,
                        allowsWrapping: false
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 3) {
                    NotificationFeedWorkspace(name: workspaceName, allowsWrapping: true)
                    NotificationFeedComputer(
                        name: computerName,
                        isReachable: computerIsReachable,
                        allowsWrapping: true
                    )
                }
            }
        }
    }
}

private struct NotificationFeedWorkspace: View {
    let name: String
    let allowsWrapping: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "rectangle.stack")
                .accessibilityHidden(true)
            Text(name)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(allowsWrapping ? 2 : 1)
    }
}

private struct NotificationFeedComputer: View {
    let name: String
    let isReachable: Bool
    let allowsWrapping: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "desktopcomputer")
                .accessibilityHidden(true)
            Text(name)
        }
        .font(.caption)
        .foregroundStyle(isReachable ? Color.secondary.opacity(0.7) : Color.orange)
        .lineLimit(allowsWrapping ? 2 : 1)
    }
}

private struct NotificationFeedContentPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
