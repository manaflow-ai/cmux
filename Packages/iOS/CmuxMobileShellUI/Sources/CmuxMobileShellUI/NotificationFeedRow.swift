#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedRow: View, Equatable {
    let model: NotificationFeedRowModel
    let actions: NotificationFeedActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    private var item: MobileNotificationFeedItem { model.item }

    var body: some View {
        Button {
            open()
        } label: {
            NotificationFeedRowLabel(
                title: item.title,
                createdAt: item.createdAt,
                isRead: item.isRead,
                presentation: model.presentation
            )
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: {
            Button {
                open()
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
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.string(
            "mobile.notificationFeed.openHint",
            defaultValue: "Opens this notification's workspace."
        ))
        .accessibilityActions {
            Button(L10n.string("mobile.notificationFeed.open", defaultValue: "Open")) {
                open()
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

    private func open() {
        actions.open(item)
    }

    private var accessibilitySuffix: String {
        "\(item.macDeviceID)-\(item.macInstanceTag ?? "legacy")-\(item.notificationID)"
    }

    /// Joins the precomputed details with a render-time relative date, so the
    /// spoken timestamp stays current even when cached models republish.
    private var accessibilityValue: String {
        (model.presentation.accessibilityDetails
            + [item.createdAt.formatted(.relative(presentation: .named))])
            .formatted()
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
        // No overlay: the previous read-state overlay stroked Color.clear
        // (invisible) while still costing a layout node in every cell's
        // self-sizing pass.
        Circle()
            .fill(isRead ? Color.clear : Color.accentColor)
            .frame(width: 6, height: 6)
            .padding(.top, 5)
            .accessibilityHidden(true)
    }
}

// Icon-and-label lines are single interpolated `Text`s rather than
// HStack{Image, Text} pairs: cell self-sizing dominated the scroll profile,
// and every stack and image node here is measured again for each trial layout
// a materializing cell runs. The row ignores child accessibility, so the
// interpolated symbols never reach VoiceOver.
private struct NotificationFeedHeadline: View {
    let title: String
    let createdAt: Date
    let isRead: Bool
    let representsWorkspace: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            titleText
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 6)

            Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var titleText: Text {
        let base = Text(title)
            .font(.subheadline)
            .fontWeight(isRead ? .medium : .semibold)
            .foregroundStyle(.primary)
        guard representsWorkspace else { return base }
        return Text(Image(systemName: "rectangle.stack"))
            .font(.caption)
            .foregroundStyle(.secondary)
            + Text(" ")
            + base
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
        (Text(Image(systemName: "rectangle.stack")) + Text(" ") + Text(name))
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
        (Text(Image(systemName: "desktopcomputer")) + Text(" ") + Text(name))
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
