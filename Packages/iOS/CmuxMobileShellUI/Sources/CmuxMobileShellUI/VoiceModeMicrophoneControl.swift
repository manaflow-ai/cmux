#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Primary Voice Mode control with an explicit listening state.
struct VoiceModeMicrophoneControl: View {
    let isListening: Bool
    let isStarting: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isListening ? Color.red : Color.accentColor)
                        .frame(width: 112, height: 112)
                        .shadow(color: (isListening ? Color.red : Color.accentColor).opacity(0.25), radius: 16, y: 8)
                    if isStarting {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            // Starting remains cancellable, so a slow permission or engine path
            // never traps the user behind a disabled microphone control.
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("MobileVoiceModeMicButton")

            Text(accessibilityLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isEnabled ? .primary : .secondary)
        }
    }

    private var accessibilityLabel: String {
        if isStarting {
            return L10n.string("mobile.settings.voice.preparing", defaultValue: "Preparing…")
        }
        return isListening
            ? L10n.string("mobile.voiceMode.stopListening", defaultValue: "Stop Listening")
            : L10n.string("mobile.voiceMode.startListening", defaultValue: "Start Listening")
    }
}
#endif
