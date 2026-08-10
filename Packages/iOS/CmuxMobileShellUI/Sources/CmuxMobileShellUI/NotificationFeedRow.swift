#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct NotificationFeedRow: View, Equatable {
    let model: NotificationFeedRowModel
    let design: MobileNotificationFeedDesign
    let actions: NotificationFeedActions

    @State private var isReplying = false
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendFailed = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && lhs.design == rhs.design
    }

    private var item: MobileNotificationFeedItem { model.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canOpen {
                Button {
                    open()
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(L10n.string(
                    "mobile.notificationFeed.openHint",
                    defaultValue: "Opens this notification's workspace."
                ))
            } else {
                rowLabel
                    .accessibilityLabel(item.title)
                    .accessibilityValue(accessibilityValue)
            }

            interactionControls
        }
        .contextMenu(menuItems: {
            if canOpen {
                Button {
                    open()
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.open", defaultValue: "Open"),
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedOpenMenu-\(accessibilitySuffix)")
            }

            if canReply {
                Button {
                    isReplying = true
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.reply", defaultValue: "Reply"),
                        systemImage: "arrowshape.turn.up.left"
                    )
                }
            }

            if canChangeReadState, !item.isRead {
                Button {
                    actions.markRead(item)
                } label: {
                    Label(
                        L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read"),
                        systemImage: "envelope.open"
                    )
                }
                .accessibilityIdentifier("MobileNotificationFeedMarkReadMenu-\(accessibilitySuffix)")
            } else if canChangeReadState {
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
            if canChangeReadState, !item.isRead {
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
            } else if canChangeReadState {
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
        .accessibilityActions {
            if canOpen {
                Button(L10n.string("mobile.notificationFeed.open", defaultValue: "Open")) {
                    open()
                }
            }
            if canChangeReadState, !item.isRead {
                Button(L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read")) {
                    actions.markRead(item)
                }
            } else if canChangeReadState {
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

    private var rowLabel: some View {
        NotificationFeedRowLabel(
            title: item.title,
            createdAt: item.createdAt,
            isRead: item.isRead,
            presentation: model.presentation,
            design: design
        )
    }

    private var canOpen: Bool {
        switch item.interaction {
        case .permission, .exitPlan, .questions:
            return item.remoteSurfaceID != nil
        default:
            return true
        }
    }

    private var canReply: Bool {
        guard item.remoteSurfaceID != nil, item.connectionStatus == .connected else { return false }
        switch item.interaction {
        case .terminalReply, nil:
            return true
        default:
            return false
        }
    }

    private var canChangeReadState: Bool {
        switch item.interaction {
        case .permission, .exitPlan, .questions:
            return false
        default:
            return true
        }
    }

    @ViewBuilder private var interactionControls: some View {
        switch item.interaction {
        case .permission:
            NotificationFeedPermissionControls(item: item, design: design, action: actions.decidePermission)
        case .exitPlan(_, let defaultMode):
            NotificationFeedExitPlanControls(
                item: item,
                design: design,
                defaultMode: defaultMode,
                action: actions.decideExitPlan
            )
        case .questions(_, let prompts):
            NotificationFeedQuestionControls(
                item: item,
                design: design,
                prompts: prompts,
                action: actions.answerQuestions
            )
        case .terminalReply, nil:
            if canReply { inlineReply }
        }
    }

    @ViewBuilder private var inlineReply: some View {
        if isReplying {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    L10n.string(
                        "mobile.notificationFeed.reply.placeholder",
                        defaultValue: "Message the agent…"
                    ),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendReply)
                .accessibilityIdentifier("MobileNotificationFeedReplyField-\(accessibilitySuffix)")

                Button(action: sendReply) {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.string(
                    "mobile.notificationFeed.reply.send",
                    defaultValue: "Send Reply"
                ))
                .accessibilityIdentifier("MobileNotificationFeedReplySend-\(accessibilitySuffix)")
            }
            if sendFailed {
                Text(L10n.string(
                    "mobile.notificationFeed.reply.failed",
                    defaultValue: "Reply wasn't sent. Check the Mac connection and try again."
                ))
                .font(.caption)
                .foregroundStyle(.red)
            }
        } else {
            Button {
                isReplying = true
            } label: {
                Label(
                    L10n.string("mobile.notificationFeed.reply", defaultValue: "Reply"),
                    systemImage: "arrowshape.turn.up.left"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("MobileNotificationFeedReply-\(accessibilitySuffix)")
        }
    }

    private func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendFailed = false
        Task { @MainActor in
            let sent = await actions.reply(item, text)
            isSending = false
            sendFailed = !sent
            if sent {
                draft = ""
                isReplying = false
                if canChangeReadState { actions.markRead(item) }
            }
        }
    }

    private var accessibilitySuffix: String {
        "\(item.macDeviceID)-\(item.notificationID)"
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
    let design: MobileNotificationFeedDesign

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch design {
            case .timeline:
                timeline
            case .cards:
                timeline
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            case .compact:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NotificationFeedUnreadIndicator(isRead: isRead)
                    Text(title)
                        .font(.subheadline.weight(isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(presentation.workspaceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.vertical, 5)
            case .conversation:
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.accentColor.gradient)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Text(String(presentation.workspaceName.prefix(1)).localizedUppercase)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    timeline
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.accentColor.opacity(isRead ? 0.06 : 0.12))
                        )
                }
            case .commandCenter:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            isRead
                                ? L10n.string("mobile.notificationFeed.design.update", defaultValue: "Update")
                                : L10n.string(
                                    "mobile.notificationFeed.design.actionNeeded",
                                    defaultValue: "Action Needed"
                                ),
                            systemImage: isRead ? "checkmark.circle" : "bolt.fill"
                        )
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isRead ? .secondary : Color.orange)
                        Spacer()
                        Text(createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(title)
                        .font(.headline)
                    if let contentPreview = presentation.contentPreview {
                        NotificationFeedContentPreview(text: contentPreview)
                    }
                    NotificationFeedProvenance(
                        workspaceName: presentation.workspaceName,
                        workspaceMatchesTitle: presentation.workspaceMatchesTitle,
                        computerName: presentation.computerName,
                        computerIsReachable: presentation.connectionStatus == .connected
                    )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isRead ? Color.secondary.opacity(0.2) : Color.orange.opacity(0.55))
                )
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private var timeline: some View {
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
