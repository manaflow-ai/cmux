import SwiftUI

struct ChatTranscriptLoadFailedPlaceholderView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(
                String(
                    localized: "chat.transcript.load_failed",
                    defaultValue: "Couldn't load this conversation",
                    bundle: .module
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button(action: onRetry) {
                Text(String(localized: "chat.transcript.retry", defaultValue: "Retry", bundle: .module))
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ChatTranscriptRetry")
        }
        .padding(.vertical, 48)
    }
}

struct ChatTranscriptPendingPlaceholderView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text(
                String(
                    localized: "chat.transcript.pending.title",
                    defaultValue: "Waiting for transcript",
                    bundle: .module
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(
                String(
                    localized: "chat.transcript.pending.subtitle",
                    defaultValue: "Messages will appear when the Mac finds the transcript.",
                    bundle: .module
                )
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .accessibilityIdentifier("ChatTranscriptPending")
    }
}
