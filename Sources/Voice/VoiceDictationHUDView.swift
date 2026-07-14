import CmuxVoice
import SwiftUI

/// Compact floating HUD shown while dictation is active: a pulsing
/// recording dot, the live transcript (volatile tail included), and a
/// click-to-stop button.
struct VoiceDictationHUDView: View {
    let controller: DictationController

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            recordingDot
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !transcriptTail.isEmpty {
                    Text(transcriptTail)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(minWidth: 130, maxWidth: 360, alignment: .leading)
            Button {
                controller.toggle()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "voice.hud.stop.help",
                defaultValue: "Stop dictation"
            ))
            .accessibilityLabel(String(
                localized: "voice.hud.stop.accessibility",
                defaultValue: "Stop voice dictation"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { pulsing = true }
    }

    private var recordingDot: some View {
        Circle()
            .fill(isListening ? Color.red : Color.orange)
            .frame(width: 9, height: 9)
            .opacity(pulsing && isListening ? 0.35 : 1)
            .animation(
                isListening
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing && isListening
            )
    }

    private var isListening: Bool { controller.phase == .listening }

    private var statusText: String {
        switch controller.phase {
        case .requestingAuthorization:
            return String(
                localized: "voice.hud.status.requestingAccess",
                defaultValue: "Requesting access…"
            )
        case .preparing:
            return String(
                localized: "voice.hud.status.preparing",
                defaultValue: "Preparing speech model…"
            )
        case .listening:
            return String(localized: "voice.hud.status.listening", defaultValue: "Listening…")
        case .stopping:
            return String(localized: "voice.hud.status.finishing", defaultValue: "Finishing…")
        case .idle, .failed:
            return ""
        }
    }

    private var transcriptTail: String {
        String(controller.transcript.displayText.suffix(60))
    }
}
