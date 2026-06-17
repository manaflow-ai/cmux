import SwiftUI

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
