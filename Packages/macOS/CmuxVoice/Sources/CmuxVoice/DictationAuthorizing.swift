import Foundation

/// Checks and requests the permissions a dictation session needs.
///
/// ``SystemDictationAuthorizer`` is the production conformance; tests pass a
/// fake that scripts each status so ``DictationController``'s denial paths
/// are deterministic.
public protocol DictationAuthorizing: Sendable {
    /// Current microphone authorization without prompting.
    func microphoneAuthorization() async -> DictationAuthorizationStatus

    /// Shows the system microphone prompt.
    ///
    /// - Returns: `true` when the user granted access.
    func requestMicrophoneAuthorization() async -> Bool

    /// Current speech-recognition authorization without prompting.
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus

    /// Shows the system speech-recognition prompt.
    ///
    /// - Returns: `true` when the user granted access (or none is needed).
    func requestSpeechRecognitionAuthorization() async -> Bool
}
