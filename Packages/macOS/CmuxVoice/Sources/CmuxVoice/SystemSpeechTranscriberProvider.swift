import Foundation

/// Picks the on-device speech engine for the running OS.
///
/// macOS 26+ uses the SpeechAnalyzer/SpeechTranscriber API family with
/// managed model assets; macOS 14–25 uses `SFSpeechRecognizer` restricted
/// to on-device recognition. The choice is per-OS, never per-session:
/// on macOS 26 an unsupported language fails rather than silently
/// degrading to the legacy engine.
public struct SystemSpeechTranscriberProvider: Sendable {
    /// Creates a provider.
    public init() {}

    /// Returns a fresh single-session transcriber for the current OS.
    public func makeTranscriber() -> any SpeechTranscribing {
        if #available(macOS 26.0, *) {
            return SpeechAnalyzerDictationTranscriber()
        }
        return SFSpeechDictationTranscriber()
    }
}
