#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedRow: View, Equatable {
    let model: NotificationFeedRowModel
    let actions: NotificationFeedActions
    var context: NotificationFeedRowContext = .standalone
    var disclosure: NotificationFeedDisclosure? = nil
    var toggleGroup: @MainActor () -> Void = {}

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.context == rhs.context && lhs.disclosure == rhs.disclosure
    }

    var body: some View {
        // Group controls own a bottom-trailing slot, not a full-height
        // column that narrows the ordinary row's headline and provenance.
        VStack(alignment: .trailing, spacing: 0) {
            NotificationFeedOpenRow(model: model, actions: actions, context: context)
                .equatable()
                .frame(maxWidth: .infinity)

            if let disclosure {
                NotificationFeedDisclosureButton(
                    disclosure: disclosure,
                    notificationID: model.notificationID,
                    toggle: toggleGroup
                )
            }
        }
    }
}

private struct NotificationFeedDisclosureButton: View {
    let disclosure: NotificationFeedDisclosure
    let notificationID: String
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(disclosure.count, format: .number)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(disclosure.isExpanded
            ? L10n.string("mobile.notificationFeed.history.hide", defaultValue: "Hide earlier notifications")
            : L10n.string("mobile.notificationFeed.history.show", defaultValue: "Show earlier notifications"))
        .accessibilityValue(L10n.string(
            "mobile.notificationFeed.history.count",
            defaultValue: "\(disclosure.count) updates"
        ))
        .accessibilityIdentifier("MobileNotificationFeedGroupToggle-\(notificationID)")
    }
}

/// The original row remains the shared open/read/context-menu entry point.
private struct NotificationFeedOpenRow: View, Equatable {
    let model: NotificationFeedRowModel
    let actions: NotificationFeedActions
    let context: NotificationFeedRowContext

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.context == rhs.context
    }

    private var item: MobileNotificationFeedItem { model.item }

    var body: some View {
        Button {
            open()
        } label: {
            NotificationFeedRowLabel(
                createdAt: item.createdAt,
                isRead: item.isRead,
                presentation: model.presentation,
                context: context
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
        .accessibilityLabel(model.presentation.headline)
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
    let createdAt: Date
    let isRead: Bool
    let presentation: NotificationFeedRowPresentation
    let context: NotificationFeedRowContext

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NotificationFeedUnreadIndicator(isRead: isRead)

            VStack(alignment: .leading, spacing: 4) {
                if context.hidesHeadline {
                    NotificationFeedHistoryHeader(
                        sourceName: context.hidesSource ? nil : presentation.sourceName,
                        contentPreview: presentation.contentPreview,
                        createdAt: createdAt
                    )
                    if !context.hidesComputer {
                        NotificationFeedProvenance(
                            sourceName: nil,
                            computerName: presentation.computerName,
                            computerIsReachable: presentation.connectionStatus == .connected
                        )
                    }
                } else {
                    NotificationFeedHeadline(
                        title: presentation.headline,
                        createdAt: createdAt,
                        isRead: isRead
                    )

                    NotificationFeedProvenance(
                        sourceName: context.hidesSource ? nil : presentation.sourceName,
                        computerName: context.hidesComputer ? nil : presentation.computerName,
                        computerIsReachable: presentation.connectionStatus == .connected
                    )
                }

                if let contentPreview = presentation.contentPreview,
                   !context.hidesHeadline || (!context.hidesSource && presentation.sourceName != nil) {
                    NotificationFeedContentPreview(text: contentPreview)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }
}

/// Inherited labels disappear, but content and dates use the ordinary row's
/// typography and date formatter. A distinct notification title stays visible.
private struct NotificationFeedHistoryHeader: View {
    let sourceName: String?
    let contentPreview: String?
    let createdAt: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sourceName {
                NotificationFeedSource(name: sourceName, allowsWrapping: true)
                    .layoutPriority(1)
            } else if let contentPreview {
                NotificationFeedContentPreview(text: contentPreview)
                    .layoutPriority(1)
            }
            Spacer(minLength: 6)
            NotificationFeedTimestamp(createdAt: createdAt)
        }
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isRead ? .medium : .semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .layoutPriority(1)

            Spacer(minLength: 6)

            NotificationFeedTimestamp(createdAt: createdAt)
        }
    }
}

private struct NotificationFeedTimestamp: View {
    let createdAt: Date

    var body: some View {
        Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct NotificationFeedProvenance: View {
    let sourceName: String?
    let computerName: String?
    let computerIsReachable: Bool

    var body: some View {
        if let sourceName, let computerName {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    NotificationFeedSource(name: sourceName, allowsWrapping: false)
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
                    NotificationFeedSource(name: sourceName, allowsWrapping: true)
                    NotificationFeedComputer(
                        name: computerName,
                        isReachable: computerIsReachable,
                        allowsWrapping: true
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } else if let sourceName {
            NotificationFeedSource(name: sourceName, allowsWrapping: true)
        } else if let computerName {
            NotificationFeedComputer(
                name: computerName,
                isReachable: computerIsReachable,
                allowsWrapping: false
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct NotificationFeedSource: View {
    let name: String
    let allowsWrapping: Bool

    var body: some View {
        (Text(Image(systemName: "bell")) + Text(" ") + Text(name))
            .font(.footnote)
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
            .multilineTextAlignment(.trailing)
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
