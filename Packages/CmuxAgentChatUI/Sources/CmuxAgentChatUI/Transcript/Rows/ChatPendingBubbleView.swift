import CmuxAgentChat
import SwiftUI

/// An optimistic outgoing bubble for a prompt that has not yet echoed back
/// through the transcript, with a delivery glyph and failed-send actions.
public struct ChatPendingBubbleView: View {
    private let pending: ChatPendingOutbound
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Creates a pending bubble.
    ///
    /// - Parameters:
    ///   - pending: The optimistic outbound row.
    ///   - actions: Row action bundle (retry/discard).
    public init(pending: ChatPendingOutbound, actions: ChatRowActions) {
        self.pending = pending
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 3) {
                bubble
                    .opacity(bubbleOpacity)
                deliveryLine
            }
            .accessibilityElement(children: isFailed ? .contain : .combine)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var isFailed: Bool {
        if case .failed = pending.delivery { return true }
        return false
    }

    private var bubble: some View {
        HStack(spacing: 5) {
            if pending.attachmentCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                    Text(verbatim: "\(pending.attachmentCount)")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel(
                    String(
                        localized: "chat.pending.attachments.accessibility",
                        defaultValue: "\(pending.attachmentCount) attachments",
                        bundle: .module
                    )
                )
            }
            Text(pending.text)
                .font(.body)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            theme.outgoingBubbleFill,
            in: .rect(cornerRadius: theme.bubbleCornerRadius)
        )
    }

    private var bubbleOpacity: Double {
        switch pending.delivery {
        case .queued: return 0.6
        case .sending: return 0.75
        case .delivered, .failed: return 1
        }
    }

    @ViewBuilder
    private var deliveryLine: some View {
        switch pending.delivery {
        case .queued:
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(
                        String(
                            localized: "chat.pending.queued.accessibility",
                            defaultValue: "Queued until the agent is free",
                            bundle: .module
                        )
                    )
                // A queued send waits for the agent to go idle; if it never
                // does (e.g. a stuck task), the user can still cancel.
                Button {
                    actions.discardPending(pending.id)
                } label: {
                    Text(String(localized: "chat.pending.cancel", defaultValue: "Cancel", bundle: .module))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical, -14)
                .padding(.horizontal, -8)
            }
        case .sending:
            ChatPendingPulseGlyph()
                .accessibilityLabel(
                    String(
                        localized: "chat.pending.sending.accessibility",
                        defaultValue: "Sending",
                        bundle: .module
                    )
                )
        case .delivered:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(
                    String(
                        localized: "chat.pending.delivered.accessibility",
                        defaultValue: "Delivered",
                        bundle: .module
                    )
                )
        case .failed:
            failedLine
        }
    }

    private var failedLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(
                        localized: "chat.pending.failed.accessibility",
                        defaultValue: "Failed to send",
                        bundle: .module
                    )
                )
            Button {
                actions.retryPending(pending.id)
            } label: {
                Text(String(localized: "chat.pending.retry", defaultValue: "Retry", bundle: .module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -14)
            .padding(.horizontal, -8)
            Button {
                actions.discardPending(pending.id)
            } label: {
                Text(String(localized: "chat.pending.discard", defaultValue: "Discard", bundle: .module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -14)
            .padding(.horizontal, -8)
        }
    }
}

/// The pulsing clock glyph shown while a send call is in flight.
struct ChatPendingPulseGlyph: View {
    @State private var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "clock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .opacity(reduceMotion ? 1 : (pulsing ? 0.3 : 1))
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
