#if os(iOS)
public import CmuxChiefVoiceCore
import AVFoundation

/// Microphone access through `AVAudioApplication` (prompts the first time).
public struct MicrophonePermission: MicrophoneAuthorizing {
    /// Creates the permission adapter.
    public init() {}

    /// Returns whether the app may record.
    public func requestAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
