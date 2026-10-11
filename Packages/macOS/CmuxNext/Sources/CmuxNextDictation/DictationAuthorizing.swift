import Foundation

/// Authorization state for a permission dictation depends on.
public enum DictationAuthorizationStatus: Equatable, Sendable {
    case authorized
    /// Denied or restricted; only System Settings can change it.
    case denied
    /// Not asked yet; a request shows the system prompt.
    case undetermined
}

/// Checks and requests the permissions a dictation session needs.
/// ``SystemDictationAuthorizer`` is the production conformance; tests script
/// each status.
public protocol DictationAuthorizing: Sendable {
    /// Microphone authorization, without prompting.
    func microphoneAuthorization() async -> DictationAuthorizationStatus
    /// Shows the system microphone prompt; true when granted.
    func requestMicrophoneAuthorization() async -> Bool
    /// Speech recognition authorization, without prompting.
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus
    /// Shows the system speech recognition prompt; true when granted.
    func requestSpeechRecognitionAuthorization() async -> Bool
}
