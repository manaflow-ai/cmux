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
