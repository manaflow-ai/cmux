import AVFoundation
import Foundation
import Speech

/// Production ``DictationAuthorizing`` backed by AVFoundation and Speech.
///
/// Microphone access always goes through `AVCaptureDevice`. Speech
/// recognition authorization is only meaningful on the macOS 14–25
/// `SFSpeechRecognizer` fallback; the macOS 26+ SpeechAnalyzer engine is
/// fully on device and reports ``DictationAuthorizationStatus/notRequired``.
public struct SystemDictationAuthorizer: DictationAuthorizing {
    /// Creates an authorizer.
    public init() {}

    public func microphoneAuthorization() async -> DictationAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .undetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public func requestMicrophoneAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func speechRecognitionAuthorization() async -> DictationAuthorizationStatus {
        if #available(macOS 26.0, *) {
            return .notRequired
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .undetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public func requestSpeechRecognitionAuthorization() async -> Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        // Legacy callback API wrapped at this one seam.
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
