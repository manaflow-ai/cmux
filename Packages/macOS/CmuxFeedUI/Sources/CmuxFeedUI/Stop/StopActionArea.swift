public import AppKit
public import SwiftUI

public import CMUXAgentLaunch

/// Renders a Stop event (the agent finished a turn and is waiting for the next
/// user prompt). Shows a one-line reply field plus a Send button that types the
/// reply into the agent's terminal surface and presses Return, so the user can
/// reply without switching focus.
///
/// The view owns no live store. The in-progress reply is bound in as a
/// ``FeedStopDraft`` (`draft`), and the focus-request counter is bound in as
/// `focusRequest`; all behavior is delivered through action closures. Localized
/// strings resolve against the app's main bundle (`bundle: .main`) because the
/// `feed.stop.*` keys live in the app catalog, not the package bundle.
///
/// The two keyboard-focus seams required by ``FeedInlineTextField`` are injected
/// as closures rather than referencing the app's `AppDelegate` or the
/// `FeedKeyboardFocusView` directly:
///
/// - `moveFocusToFeedHost` asks the app to move keyboard focus to the Feed
///   sidebar host for a given window, returning `true` when it did.
/// - `responderRetainsFeedFocus` lets the app decide whether a window's new
///   first responder still belongs to the Feed focus domain, so end-of-editing
///   does not spuriously fire `onBlur` while focus hops within the Feed sidebar.
public struct StopActionArea: View {
    @Binding var draft: FeedStopDraft
    @Binding var focusRequest: Int

    let onFocusRow: () -> Void
    let onActionRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void
    let moveFocusToFeedHost: @MainActor (NSWindow) -> Bool
    let responderRetainsFeedFocus: (NSResponder) -> Bool

    /// Creates the stop-event reply action area for a feed row.
    /// - Parameters:
    ///   - draft: The in-progress reply text the user is composing.
    ///   - focusRequest: A monotonically increasing counter; incrementing it
    ///     asks the reply field to take keyboard focus (`0` means no request).
    ///   - onFocusRow: Invoked when the reply field gains focus.
    ///   - onActionRow: Invoked before a send to mark the row as acted on.
    ///   - onBlurRow: Invoked when the reply field loses focus.
    ///   - onSend: Invoked with the trimmed reply text to type into the agent.
    ///   - moveFocusToFeedHost: Focus seam for ``FeedInlineTextField`` — moves
    ///     keyboard focus to the Feed sidebar host for a window.
    ///   - responderRetainsFeedFocus: Focus seam for ``FeedInlineTextField`` —
    ///     reports whether a responder still belongs to the Feed focus domain.
    public init(
        draft: Binding<FeedStopDraft>,
        focusRequest: Binding<Int>,
        onFocusRow: @escaping () -> Void,
        onActionRow: @escaping () -> Void,
        onBlurRow: @escaping () -> Void,
        onSend: @escaping (String) -> Void,
        moveFocusToFeedHost: @escaping @MainActor (NSWindow) -> Bool,
        responderRetainsFeedFocus: @escaping (NSResponder) -> Bool
    ) {
        self._draft = draft
        self._focusRequest = focusRequest
        self.onFocusRow = onFocusRow
        self.onActionRow = onActionRow
        self.onBlurRow = onBlurRow
        self.onSend = onSend
        self.moveFocusToFeedHost = moveFocusToFeedHost
        self.responderRetainsFeedFocus = responderRetainsFeedFocus
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
                Text(String(localized: "feed.stop.label",
                            defaultValue: "Claude finished — reply to continue", bundle: .main))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            FeedInlineTextField(
                text: replyBinding,
                focusRequest: focusRequest == 0 ? nil : focusRequest,
                placeholder: String(localized: "feed.stop.placeholder",
                                    defaultValue: "Reply to Claude…", bundle: .main),
                isEnabled: true,
                font: replyFont,
                onFocus: onFocusRow,
                onBlur: onBlurRow,
                onSubmit: sendReply,
                moveFocusToFeedHost: moveFocusToFeedHost,
                responderRetainsFeedFocus: responderRetainsFeedFocus
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
                label: String(localized: "feed.stop.send",
                              defaultValue: "Send to Claude", bundle: .main),
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
