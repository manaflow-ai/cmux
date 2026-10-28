/// Asks for microphone access. The iOS adapter wraps `AVAudioApplication`.
public protocol MicrophoneAuthorizing: Sendable {
    /// Returns whether the app may record, prompting the user the first time.
    func requestAccess() async -> Bool
}
