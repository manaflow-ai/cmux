import Foundation

/// Authorization state for a capability dictation depends on.
public enum DictationAuthorizationStatus: Equatable, Sendable {
    /// The user granted access.
    case authorized

    /// The user denied access or it is restricted; the only remedy is
    /// System Settings.
    case denied

    /// The user has not been asked yet; a request will show the system
    /// permission prompt.
    case undetermined

    /// The active speech engine does not need this permission (the macOS
    /// 26+ SpeechAnalyzer path performs recognition fully on device and
    /// requires no speech-recognition authorization).
    case notRequired
}
