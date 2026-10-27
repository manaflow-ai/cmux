import AVFoundation
import Foundation
import Speech
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        // A callback dropped without an answer is no authorization.
        (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }) ?? false
    }
}
