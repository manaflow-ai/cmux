#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Plain transcript surface for finalized and in-progress recognition text.
struct VoiceModeTranscriptView: View {
    let finalizedTranscripts: [String]
    let partialTranscript: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if finalizedTranscripts.isEmpty, partialTranscript.isEmpty {
                    ContentUnavailableView {
                        Label(
                            L10n.string("mobile.voiceMode.whisperPrompt", defaultValue: "Whisper close to your iPhone."),
                            systemImage: "waveform"
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    if !finalizedTranscripts.isEmpty {
                        Text(finalizedTranscripts.joined(separator: "\n\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !partialTranscript.isEmpty {
                        Text(partialTranscript)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.title3)
            .textSelection(.enabled)
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("MobileVoiceModeTranscript")
    }
}
#endif
