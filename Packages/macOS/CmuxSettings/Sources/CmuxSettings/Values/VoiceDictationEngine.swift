/// Speech engine for voice dictation (`voice.engine`).
public enum VoiceDictationEngine: String, CaseIterable, Sendable, SettingCodable {
    /// Apple's on-device recognizer. Audio never leaves the Mac.
    case onDevice
    /// OpenAI transcription with the user's own API key. Audio is sent to
    /// OpenAI when the utterance ends.
    case openAI
}
