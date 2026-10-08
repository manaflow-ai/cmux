import Foundation

/// Why a dictation session could not start or ended early.
public enum DictationFailure: Error, Equatable, Sendable {
    /// The user denied microphone access, or policy restricts it.
    case microphoneAccessDenied
    /// The user denied speech recognition, which the `SFSpeechRecognizer`
    /// fallback needs. SpeechAnalyzer never raises this.
    case speechRecognitionAccessDenied
    /// No on-device recognizer supports the language. Dictation never falls
    /// back to server recognition.
    case onDeviceRecognitionUnavailable(localeIdentifier: String)
    /// Downloading the on-device speech model failed.
    case modelDownloadFailed(String)
    /// The audio engine could not start (no input device, capture error).
    case audioCaptureFailed(String)
    /// The recognizer failed mid-session.
    case transcriptionFailed(String)
}
