import AVFoundation
import Foundation
import Speech

/// Production ``DictationAuthorizing`` backed by AVFoundation and Speech.
///
/// Microphone access goes through `AVCaptureDevice`. Speech recognition
/// authorization matters only for the `SFSpeechRecognizer` fallback; the
/// SpeechAnalyzer engine runs on device and asks for nothing beyond the
/// microphone.
public struct SystemDictationAuthorizer: DictationAuthorizing {
    public init() {}

    public func microphoneAuthorization() async -> DictationAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestMicrophoneAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func speechRecognitionAuthorization() async -> DictationAuthorizationStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestSpeechRecognitionAuthorization() async -> Bool {
        // The callback API, wrapped at this one seam.
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
