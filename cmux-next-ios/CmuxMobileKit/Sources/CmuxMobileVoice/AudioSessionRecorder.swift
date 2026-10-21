#if os(iOS)
public import AVFoundation
public import CmuxChiefVoiceCore
public import Foundation

/// Records the microphone into an AAC (M4A) file with `AVAudioRecorder`.
///
/// Sets the shared audio session to `.playAndRecord` / `.spokenAudio` while
/// recording and releases it afterwards so other audio resumes. With the
/// `audio` background mode the recording continues while the phone is locked.
/// ``interruptions()`` reports a phone call, Siri or another recording taking
/// the session; the composition root ends the call on it.
@MainActor
public final class AudioSessionRecorder: VoiceRecording {
    private let session: AVAudioSession
    private var recorder: AVAudioRecorder?

    /// Creates a recorder over `session` (the app passes `AVAudioSession.sharedInstance()`).
    /// - Parameter session: The audio session to configure while recording.
    public init(session: AVAudioSession) {
        self.session = session
    }

    /// Starts recording into `url`.
    /// - Throws: When the session cannot activate or the recorder cannot start.
    public func start(writingTo url: URL) async throws {
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioSessionRecorderError.couldNotStart
        }
        self.recorder = recorder
    }

    /// Stops recording, releases the session and returns the recorded seconds.
    public func stop() async -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    /// Yields once each time another audio user interrupts the session.
    public nonisolated func interruptions() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // NSKeyValueObservation-style token API at the seam (Notification is not
            // Sendable, so no async sequence); only the Void signal leaves it.
            nonisolated(unsafe) let token = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began { continuation.yield() }
            }
            // The token is only handed back to NotificationCenter, which is thread-safe.
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// Why ``AudioSessionRecorder`` could not record.
public enum AudioSessionRecorderError: Error, Sendable {
    /// `AVAudioRecorder.record()` returned false.
    case couldNotStart
}
#endif
