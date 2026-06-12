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
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .sending:
            ChatPendingPulseGlyph()
        case .delivered:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .failed:
            failedLine
        }
    }

    private var failedLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Button {
                actions.retryPending(pending.id)
            } label: {
                Text(String(localized: "chat.pending.retry", defaultValue: "Retry", bundle: .module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            Button {
                actions.discardPending(pending.id)
            } label: {
                Text(String(localized: "chat.pending.discard", defaultValue: "Discard", bundle: .module))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The pulsing clock glyph shown while a send call is in flight.
struct ChatPendingPulseGlyph: View {
    @State private var pulsing = false

    var body: some View {
        Image(systemName: "clock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .opacity(pulsing ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
