#if os(iOS)
import AVFoundation
import Foundation
import Speech

/// Requests microphone and Speech permissions for voice capture.
public struct VoicePermissionRequester {
    /// Creates a permission requester.
    public init() {}

    /// Requests permissions needed by the selected voice engine.
    /// - Parameter engine: The engine that will run.
    /// - Returns: `true` when the required permissions were granted.
    public func requestPermissions(for engine: VoiceEngineID) async -> Bool {
        let micGranted = await Self.requestMicrophonePermission()
        guard micGranted else { return false }
        guard engine == .apple else { return true }
        return await Self.requestSpeechPermission()
    }

    private nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
#endif
