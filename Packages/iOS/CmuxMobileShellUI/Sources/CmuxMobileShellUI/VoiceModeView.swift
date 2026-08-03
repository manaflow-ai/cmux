#if os(iOS)
import CmuxMobileShell
import CmuxVoice
import SwiftUI

/// Selects the explicitly enabled Voice Mode implementation.
struct VoiceModeView: View {
    @Environment(VoiceSettingsStore.self) private var voiceSettings

    let store: CMUXMobileShellStore
    let connectedHostName: String

    var body: some View {
        if voiceSettings.gptVoiceEnabled {
            GPTVoiceModeView(
                store: store,
                connectedHostName: connectedHostName
            )
        } else {
            DictationVoiceModeView(
                store: store,
                connectedHostName: connectedHostName
            )
        }
    }
}
#endif
