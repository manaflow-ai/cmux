import Foundation

/// Reasons a voice-dictation session could not start or ended abnormally.
public enum DictationFailure: Error, Equatable, Sendable {
    /// The user denied microphone access (or it is restricted by policy).
    case microphoneAccessDenied

    /// The user denied speech-recognition access (SFSpeechRecognizer path
    /// on macOS 14–25; the macOS 26+ SpeechAnalyzer path never raises this).
    case speechRecognitionAccessDenied

    /// No on-device recognizer supports the requested language, or the
    /// recognizer refused on-device-only operation. cmux never falls back
    /// to server-based recognition.
    case onDeviceRecognitionUnavailable(localeIdentifier: String)

    /// Downloading the on-device speech model assets failed.
    case modelDownloadFailed(String)

    /// The audio engine could not start (no input device, capture error).
    case audioCaptureFailed(String)

    /// The recognizer reported an unrecoverable error mid-session.
    case transcriptionFailed(String)

    /// No insertable target (terminal surface, text field, or editable
    /// web content) had focus when the session started, or the pinned
    /// target went away mid-session.
    case insertionTargetUnavailable
}
