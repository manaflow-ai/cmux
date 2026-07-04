import CmuxFoundation
import CmuxInbox
import SwiftUI

struct InboxThreadDetailView: View {
    let thread: InboxThread?
    let recentItems: [InboxItem]
    let draft: InboxDraft?
    let sendState: InboxDraftSendState
    @Binding var draftBody: String
    let onDraft: (String) -> Void
    let onDraftBodyChanged: (String) -> Void
    let onSend: () -> Void
    let onOpenOriginal: () -> Void
    let onMarkRead: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thread {
                header(thread)
                Divider()
                recentContext
                Divider()
                draftSurface(thread)
            } else {
                emptySelection
            }
        }
        .accessibilityIdentifier("InboxThreadDetail")
    }

    private func header(_ thread: InboxThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.title)
                    .cmuxFont(size: 13, weight: .semibold)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if thread.unreadCount > 0 {
                    Text("\(thread.unreadCount)")
                        .cmuxFont(size: 10, weight: .semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }

            Text(InboxLocalized.sourceLabel(thread.source))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    onMarkRead(thread.threadID)
                } label: {
                    Label(String(localized: "inbox.detail.markRead", defaultValue: "Mark Read"), systemImage: "checkmark.circle")
                }
                .controlSize(.small)

                if thread.externalURL != nil {
                    Button {
                        onOpenOriginal()
                    } label: {
                        Label(String(localized: "inbox.detail.openOriginal", defaultValue: "Open Original"), systemImage: "arrow.up.forward.square")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
    }

    private var recentContext: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if recentItems.isEmpty {
                    Text(String(localized: "inbox.detail.noContext", defaultValue: "No recent context."))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recentItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.sender.displayName)
                                    .cmuxFont(size: 11, weight: .semibold)
                                Spacer(minLength: 8)
                                Text(Self.timeFormatter.string(from: item.timestamp))
                                    .cmuxFont(size: 10)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.body ?? item.bodyPreview)
                                .cmuxFont(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func draftSurface(_ thread: InboxThread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "inbox.detail.reply", defaultValue: "Reply"))
                    .cmuxFont(size: 12, weight: .semibold)
                Spacer()
                Button {
                    onDraft(thread.threadID)
                } label: {
                    Label(String(localized: "inbox.detail.draftReply", defaultValue: "Draft Reply"), systemImage: "square.and.pencil")
                }
                .controlSize(.small)
            }

            TextEditor(text: Binding(
                get: { draftBody },
                set: { value in
                    draftBody = value
                    onDraftBodyChanged(value)
                }
            ))
            .font(.system(size: 12))
            .frame(minHeight: 88)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            )
            .disabled(draft == nil)
            .accessibilityIdentifier("InboxDraftTextEditor")

            Text(String(localized: "inbox.detail.approvalCopy", defaultValue: "cmux never sends external replies until you approve Send."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if let draftStatus = draft?.status {
                    Text(statusText(draftStatus))
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .none) {
                    onSend()
                } label: {
                    Label(sendButtonTitle, systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sendState != .requiresApproval)
                .accessibilityIdentifier("InboxSendApprovedReplyButton")
            }
        }
        .padding(10)
    }

    private var emptySelection: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "inbox.detail.empty.title", defaultValue: "Select a thread"))
                .cmuxFont(size: 13, weight: .medium)
            Text(String(localized: "inbox.detail.empty.subtitle", defaultValue: "Recent context, drafts, approved sends, and source links appear here."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sendButtonTitle: String {
        switch sendState {
        case .noDraft:
            return String(localized: "inbox.detail.send.noDraft", defaultValue: "Send")
        case .emptyDraft:
            return String(localized: "inbox.detail.send.emptyDraft", defaultValue: "Send")
        case .requiresApproval:
            return String(localized: "inbox.detail.send.requiresApproval", defaultValue: "Send")
        case .sent:
            return String(localized: "inbox.detail.send.sent", defaultValue: "Sent")
        case .failed:
            return String(localized: "inbox.detail.send.failed", defaultValue: "Retry Send")
        }
    }

    private func statusText(_ status: InboxDraftStatus) -> String {
        switch status {
        case .editing:
            return String(localized: "inbox.detail.draftStatus.editing", defaultValue: "Draft")
        case .approved:
            return String(localized: "inbox.detail.draftStatus.approved", defaultValue: "Sending")
        case .sent:
            return String(localized: "inbox.detail.draftStatus.sent", defaultValue: "Sent")
        case .failed:
            return String(localized: "inbox.detail.draftStatus.failed", defaultValue: "Send failed")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
