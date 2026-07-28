#if os(iOS)
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

/// Scrollable user and assistant transcript for a GPT Voice session.
struct GPTVoiceConversationView: View {
    let transcripts: [RealtimeVoiceTranscriptEntry]
    let partialUserTranscript: String
    let partialAssistantTranscript: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcripts.isEmpty,
                       partialUserTranscript.isEmpty,
                       partialAssistantTranscript.isEmpty {
                        ContentUnavailableView {
                            Label(
                                L10n.string(
                                    "mobile.voiceMode.gpt.prompt",
                                    defaultValue: "Ask GPT to choose a terminal, then speak the exact text to send."
                                ),
                                systemImage: "waveform.and.mic"
                            )
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(transcripts) { entry in
                            transcriptBubble(
                                role: entry.role,
                                text: entry.text,
                                isPartial: false
                            )
                        }
                        if !partialUserTranscript.isEmpty {
                            transcriptBubble(
                                role: .user,
                                text: partialUserTranscript,
                                isPartial: true
                            )
                        }
                        if !partialAssistantTranscript.isEmpty {
                            transcriptBubble(
                                role: .assistant,
                                text: partialAssistantTranscript,
                                isPartial: true
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id("GPTVoiceTranscriptEnd")
                }
                .padding(16)
            }
            .onChange(of: transcriptScrollKey) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("GPTVoiceTranscriptEnd", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityIdentifier("MobileGPTVoiceTranscript")
    }

    private var transcriptScrollKey: Int {
        transcripts.count
            + partialUserTranscript.utf8.count
            + partialAssistantTranscript.utf8.count
    }

    @ViewBuilder
    private func transcriptBubble(
        role: RealtimeVoiceTranscriptRole,
        text: String,
        isPartial: Bool
    ) -> some View {
        HStack {
            if role == .user {
                Spacer(minLength: 44)
            }
            Text(text)
                .font(.body)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    role == .user
                        ? Color.accentColor.opacity(0.18)
                        : Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            if role == .assistant {
                Spacer(minLength: 44)
            }
        }
    }
}
#endif
