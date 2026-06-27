public import AppKit
public import SwiftUI

/// Renders a Stop event (Claude finished a turn and is waiting for
/// the next user prompt). Shows a text field + Send button that
/// types the reply into the agent's terminal surface and presses
/// Return — so the user can reply without switching focus.
///
/// The view takes only value snapshots plus closures so it can live below the
/// Feed's list snapshot boundary. The user-facing strings (`labelText`,
/// `placeholderText`, `sendLabel`) are resolved app-side against the
/// `.xcstrings` catalog and passed in, keeping localization in the app target.
/// Relinquishing focus to the surrounding feed host and recognizing the feed
/// focus host responder are supplied by the app through the
/// `focusFeedHost`/`isFeedFocusHostResponder` closures, so the view never
/// reaches into `AppDelegate` directly.
public struct StopActionArea: View {
    @Binding var draft: FeedStopDraft
    @Binding var focusRequest: Int

    let labelText: String
    let placeholderText: String
    let sendLabel: String

    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void
    let focusFeedHost: (NSWindow) -> Bool
    let isFeedFocusHostResponder: (NSResponder?) -> Bool

    /// Creates a stop action area.
    ///
    /// - Parameters:
    ///   - draft: The in-progress reply, bound back to the feed panel.
    ///   - focusRequest: A monotonically increasing focus nudge for the reply
    ///     field; `0` means "no focus requested".
    ///   - labelText: The localized "Claude finished" header label.
    ///   - placeholderText: The localized reply-field placeholder.
    ///   - sendLabel: The localized send-button label.
    ///   - onFocusRow: Invoked when the reply field gains focus.
    ///   - onActionRow: Invoked when the user presses Send.
    ///   - onBlurRow: Invoked when the reply field relinquishes focus.
    ///   - onSend: Sends the trimmed reply text back to the agent.
    ///   - focusFeedHost: Moves focus to the surrounding feed host for a window;
    ///     returns whether the host accepted focus.
    ///   - isFeedFocusHostResponder: Reports whether a responder is the feed
    ///     focus host.
    public init(
        draft: Binding<FeedStopDraft>,
        focusRequest: Binding<Int>,
        labelText: String,
        placeholderText: String,
        sendLabel: String,
        onFocusRow: @escaping () -> Void,
        onActionRow: @escaping () -> Void,
        onBlurRow: @escaping () -> Void,
        onSend: @escaping (String) -> Void,
        focusFeedHost: @escaping (NSWindow) -> Bool,
        isFeedFocusHostResponder: @escaping (NSResponder?) -> Bool
    ) {
        self._draft = draft
        self._focusRequest = focusRequest
        self.labelText = labelText
        self.placeholderText = placeholderText
        self.sendLabel = sendLabel
        self.onFocusRow = onFocusRow
        self.onActionRow = onActionRow
        self.onBlurRow = onBlurRow
        self.onSend = onSend
        self.focusFeedHost = focusFeedHost
        self.isFeedFocusHostResponder = isFeedFocusHostResponder
    }

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

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(labelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            FeedInlineTextField(
                text: replyBinding,
                focusRequest: focusRequest == 0 ? nil : focusRequest,
                placeholder: placeholderText,
                isEnabled: true,
                font: replyFont,
                onFocus: onFocusRow,
                onBlur: onBlurRow,
                onSubmit: sendReply,
                focusFeedHost: focusFeedHost,
                isFeedFocusHostResponder: isFeedFocusHostResponder
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
                label: sendLabel,
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
