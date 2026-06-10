import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

/// Renders a Stop event (Claude finished a turn and is waiting for
/// the next user prompt). Shows a text field + Send button that
/// types the reply into the agent's terminal surface and presses
/// Return — so the user can reply without switching focus.
struct StopActionArea: View {
    @Binding var draft: FeedStopDraft
    @Binding var focusRequest: Int

    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void

    private var trimmed: String {
        draft.reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty }
    private var replyFont: NSFont { NSFont.systemFont(ofSize: 12) }
    private var replyBinding: Binding<String> {
        Binding(
            get: { draft.reply },
            set: { draft.reply = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(String(localized: "feed.stop.label", defaultValue: "Claude finished — reply to continue"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            FeedInlineTextField(
                text: replyBinding,
                focusRequest: focusRequest == 0 ? nil : focusRequest,
                placeholder: String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…"),
                isEnabled: true,
                font: replyFont,
                onFocus: onFocusRow,
                onBlur: onBlurRow,
                onSubmit: sendReply
            )
            .frame(
                maxWidth: .infinity,
                minHeight: FeedInlineTextEditorView.minimumHeight(for: replyFont),
                alignment: .leading
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(canSend ? 0.25 : 0.10), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .feedIBeamCursorOnHover(enabled: true)
            .onTapGesture {
                onFocusRow()
                requestReplyFocus()
            }
            FeedButton(
                label: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
                leadingIcon: "arrow.up.circle.fill",
                kind: canSend ? .primary : .soft,
                size: .medium,
                fullWidth: true,
                dimmed: !canSend
            ) {
                guard canSend else { return }
                onActionRow()
                sendReply()
            }
        }
    }

    private func requestReplyFocus() {
        focusRequest += 1
    }

    private func sendReply() {
        guard canSend else { return }
        onSend(trimmed)
        draft.reply = ""
    }
}

