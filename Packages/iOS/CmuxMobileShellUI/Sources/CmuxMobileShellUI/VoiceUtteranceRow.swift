#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct VoiceUtteranceRow: View {
    let utterance: VoiceUtterance
    let resend: () -> Void

    var body: some View {
        Button(action: resend) {
            VStack(alignment: .leading, spacing: 6) {
                Text(utterance.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusLine
                    .font(.caption)
                    .foregroundStyle(statusTint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(utterance.status.isSending)
        .accessibilityIdentifier("MobileVoiceModeUtteranceRow-\(utterance.id.uuidString)")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch utterance.status {
        case .sending:
            Text(L10n.string("mobile.voiceMode.utteranceSending", defaultValue: "Sending..."))
        case .sent(let targetTitle):
            Text(
                String.localizedStringWithFormat(
                    L10n.string("mobile.voiceMode.utteranceSentFormat", defaultValue: "→ %@"),
                    targetTitle
                )
            )
        case .failed(let message, _):
            Text(message)
        }
    }

    private var statusTint: Color {
        switch utterance.status {
        case .sending, .sent:
            return .secondary
        case .failed(_, let isTargetChanged):
            return isTargetChanged ? .orange : .red
        }
    }
}
#endif
