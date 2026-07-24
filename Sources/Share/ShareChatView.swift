import CmuxWorkspaceShare
import SwiftUI

/// Share-session chat panel content for the one focused shared workspace.
/// Rows below `ForEach` boundaries receive value snapshots and actions only.
struct ShareChatView: View {
    let controller: ShareSessionController
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if let errorText = controller.lastErrorText {
                Divider()
                errorBanner(errorText)
            }
            Divider()
            feedSection
            Divider()
            participantsSection
            Divider()
            inputBar
        }
        .frame(minWidth: 280, minHeight: 340)
    }

    // MARK: - Header

    private var statusColor: Color {
        switch controller.status {
        case .idle: return .gray
        case .starting: return .yellow
        case .active: return .green
        case .reconnecting: return .orange
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle:
            return String(localized: "share.chat.status.idle", defaultValue: "Not sharing")
        case .starting:
            return String(localized: "share.chat.status.starting", defaultValue: "Starting…")
        case .active:
            return String(localized: "share.chat.status.active", defaultValue: "Live")
        case .reconnecting:
            return String(localized: "share.chat.status.reconnecting", defaultValue: "Reconnecting…")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                controller.copyShareLink()
            } label: {
                Text(String(localized: "share.chat.copyLink", defaultValue: "Copy Link"))
            }
            .controlSize(.small)
            Button(role: .destructive) {
                controller.stopSharing()
            } label: {
                Text(String(localized: "share.chat.stopSharing", defaultValue: "Stop Sharing"))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.errorBanner")
    }

    // MARK: - Feed

    private var feedSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if controller.feed.isEmpty {
                        Text(String(
                            localized: "share.chat.emptyFeed",
                            defaultValue: "No messages yet. Access requests and chat will appear here."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    }
                    ForEach(controller.feed) { item in
                        ShareFeedRow(
                            item: item,
                            approve: { user, role in
                                controller.approve(user: user, role: role)
                            },
                            deny: { user in
                                controller.deny(user: user)
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: controller.feed.last?.id) { _, lastID in
                guard let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // MARK: - Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "share.chat.participantsHeader", defaultValue: "Participants"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.participants, id: \.user) { participant in
                        ShareParticipantRow(
                            participant: participant,
                            setRole: { user, role in
                                controller.setRole(user: user, role: role)
                            },
                            kick: { user in
                                controller.kick(user: user)
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 96)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "share.chat.inputPlaceholder", defaultValue: "Message"),
                text: $draft
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(Text(String(localized: "share.chat.send", defaultValue: "Send")))
        }
        .padding(10)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        controller.sendChat(text)
    }
}

// MARK: - Rows (value snapshots + closures only)

private struct ShareFeedRow: View {
    let item: ShareFeedItem
    let approve: (String, ShareRole) -> Void
    let deny: (String) -> Void

    var body: some View {
        switch item.kind {
        case .chat(_, let email, let colorIndex, let text, let hasBubble):
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color(nsColor: ShareCursorOverlayController.color(forIndex: colorIndex)))
                    .frame(width: 7, height: 7)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(email)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if hasBubble {
                            Image(systemName: "cursorarrow.rays")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
        case .accessRequest(let user, let email, let resolution):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: String(
                        localized: "share.chat.accessRequest.wantsToJoin",
                        defaultValue: "%@ wants to join"
                    ),
                    email
                ))
                .font(.system(size: 11, weight: .medium))
                if let resolution {
                    Text(resolutionText(resolution))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            approve(user, .editor)
                        } label: {
                            Text(String(
                                localized: "share.chat.accessRequest.allowEditing",
                                defaultValue: "Allow editing"
                            ))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button {
                            approve(user, .viewer)
                        } label: {
                            Text(String(
                                localized: "share.chat.accessRequest.viewOnly",
                                defaultValue: "View only"
                            ))
                        }
                        .controlSize(.small)
                        Button {
                            deny(user)
                        } label: {
                            Text(String(localized: "share.chat.accessRequest.deny", defaultValue: "Deny"))
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
    }

    private func resolutionText(_ resolution: ShareFeedItem.AccessResolution) -> String {
        switch resolution {
        case .approvedEditor:
            return String(
                localized: "share.chat.accessRequest.approvedEditor",
                defaultValue: "Approved as editor"
            )
        case .approvedViewer:
            return String(
                localized: "share.chat.accessRequest.approvedViewer",
                defaultValue: "Approved as viewer"
            )
        case .denied:
            return String(localized: "share.chat.accessRequest.denied", defaultValue: "Denied")
        }
    }
}

private struct ShareParticipantRow: View {
    let participant: ShareParticipant
    let setRole: (String, ShareRole) -> Void
    let kick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: ShareCursorOverlayController.color(forIndex: participant.color)))
                .frame(width: 7, height: 7)
                .opacity(participant.connected ? 1 : 0.35)
            Text(participant.email)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(participant.connected ? .primary : .secondary)
            if participant.isHost {
                Text(String(localized: "share.chat.hostBadge", defaultValue: "Host"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            Spacer()
            if !participant.isHost {
                Menu {
                    Button {
                        setRole(participant.user, .editor)
                    } label: {
                        Text(Self.roleTitle(.editor))
                    }
                    Button {
                        setRole(participant.user, .viewer)
                    } label: {
                        Text(Self.roleTitle(.viewer))
                    }
                } label: {
                    Text(Self.roleTitle(participant.role))
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    kick(participant.user)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(localized: "share.chat.kick", defaultValue: "Remove")))
            }
        }
    }

    static func roleTitle(_ role: ShareRole) -> String {
        switch role {
        case .editor:
            return String(localized: "share.chat.role.editor", defaultValue: "Editor")
        case .viewer:
            return String(localized: "share.chat.role.viewer", defaultValue: "Viewer")
        }
    }
}
