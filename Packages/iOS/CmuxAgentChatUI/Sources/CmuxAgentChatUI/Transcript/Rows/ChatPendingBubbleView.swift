import CmuxAgentChat
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An optimistic outgoing bubble for a prompt that has not yet echoed back
/// through the transcript, with a delivery glyph and failed-send actions.
public struct ChatPendingBubbleView: View {
    private let pending: ChatPendingOutbound
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatBubbleMaxWidth) private var bubbleMaxWidth

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
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
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
        VStack(alignment: .trailing, spacing: 6) {
            if !pending.attachments.isEmpty {
                attachmentThumbnails
            }
            if !pending.text.isEmpty {
                textRow
            }
        }
        .padding(.horizontal, pending.text.isEmpty && !pending.attachments.isEmpty ? 6 : 12)
        .padding(.vertical, pending.text.isEmpty && !pending.attachments.isEmpty ? 6 : 8)
        .background(theme.outgoingBubbleFill, in: .rect(cornerRadius: theme.bubbleCornerRadius))
    }

    /// Real previews of the images being sent (the pending row holds the
    /// encoded bytes; the reconciled transcript message is metadata-only).
    private var attachmentThumbnails: some View {
        // Wrap to at most two 96pt tiles per row so the composer's max of four
        // attachments (2×96 + spacing ≈ 196pt) fits even narrow devices like
        // iPhone SE, instead of overflowing a single HStack. One or two
        // attachments render as a single row, unchanged.
        let rows = stride(from: 0, to: pending.attachments.count, by: 2).map { start in
            Array(pending.attachments[start..<min(start + 2, pending.attachments.count)])
        }
        return VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, attachment in
                        thumbnail(for: attachment)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                localized: "chat.pending.attachments.accessibility",
                defaultValue: "\(pending.attachmentCount) attachments",
                bundle: .module
            )
        )
    }

    @ViewBuilder
    private func thumbnail(for attachment: ChatOutboundAttachment) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 10))
        } else {
            thumbnailFallback
        }
        #else
        thumbnailFallback
        #endif
    }

    private var thumbnailFallback: some View {
        Image(systemName: "photo")
            .font(.title2)
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 96, height: 96)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private var textRow: some View {
        Text(pending.text)
            .font(.body)
            .foregroundStyle(.white)
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
