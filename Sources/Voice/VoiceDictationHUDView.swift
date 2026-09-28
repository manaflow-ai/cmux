import CmuxVoice
import SwiftUI

/// Compact floating HUD shown while dictation is active: a pulsing
/// recording dot, an input level meter, the live transcript (volatile tail
/// included), and a click-to-stop button.
struct VoiceDictationHUDView: View {
    let snapshot: VoiceDictationHUDSnapshot
    let levelMeter: DictationAudioLevelMeter
    let stopAction: @MainActor () -> Void

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            recordingDot
            if isListening {
                VoiceDictationLevelMeterView(meter: levelMeter)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !transcriptTail.isEmpty {
                    Text(transcriptTail)
                        .accessibilityIdentifier("VoiceDictationHUDTranscript")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(minWidth: 130, maxWidth: 360, alignment: .leading)
            Button {
                stopAction()
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

    private var isListening: Bool { snapshot.phase == .listening }

    private var statusText: String {
        switch snapshot.phase {
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
            if snapshot.usesCloudEngine {
                return String(localized: "voice.hud.status.listeningCloud", defaultValue: "Listening… (OpenAI)")
            }
            return String(localized: "voice.hud.status.listening", defaultValue: "Listening…")
        case .stopping:
            if snapshot.usesCloudEngine {
                return String(localized: "voice.hud.status.transcribing", defaultValue: "Transcribing…")
            }
            return String(localized: "voice.hud.status.finishing", defaultValue: "Finishing…")
        case .idle, .failed:
            return ""
        }
    }

    private var transcriptTail: String { snapshot.transcriptTail }
}

/// Five bars that follow the microphone level while listening.
///
/// Reads the meter at display rate through `TimelineView` rather than
/// observing it, so audio-thread updates never invalidate SwiftUI state.
private struct VoiceDictationLevelMeterView: View {
    let meter: DictationAudioLevelMeter

    /// Relative bar heights, tallest in the middle, like a voice waveform.
    private static let barWeights: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
            let level = CGFloat(meter.level)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Self.barWeights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 3, height: 3 + 13 * level * Self.barWeights[index])
                }
            }
            .frame(height: 16)
            .animation(.linear(duration: 0.08), value: level)
        }
        .accessibilityElement()
        .accessibilityIdentifier("VoiceDictationLevelMeter")
        .accessibilityLabel(String(
            localized: "voice.hud.levelMeter.accessibility",
            defaultValue: "Microphone level"
        ))
    }
}
