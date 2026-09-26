import AVFoundation
import Foundation
import Speech

/// Authorization outcome for a dictation start attempt.
public enum DictationAuthorizationOutcome: Sendable, Equatable {
    /// Both permissions granted.
    case granted
    /// At least one permission explicitly denied.
    case denied
    /// At least one permission never requested.
    case undetermined
}

/// Speech + microphone authorization seam for ``DictationController``.
///
/// Injected so tests decide outcomes deterministically; the app wiring passes
/// ``systemLive``. `resolve` performs synchronous status reads only (never
/// invokes a TCC completion), matching the crash-avoidance shape of the iOS
/// composer dictation controller.
public struct DictationAuthorization: Sendable {
    /// Reads the current outcome without prompting.
    public var resolve: @Sendable () -> DictationAuthorizationOutcome

    /// Requests both permissions; `true` when both granted. May prompt.
    public var request: @Sendable () async -> Bool

    /// The real macOS TCC-backed resolver.
    public static let systemLive = DictationAuthorization(
        resolve: {
            let speech = SFSpeechRecognizer.authorizationStatus()
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            guard speech != .notDetermined, mic != .notDetermined else { return .undetermined }
            return (speech == .authorized && mic == .authorized) ? .granted : .denied
        },
        request: {
            let speechGranted: Bool = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard speechGranted else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    )
}
