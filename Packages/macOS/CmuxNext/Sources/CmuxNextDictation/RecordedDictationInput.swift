#if DEBUG
import AVFoundation
import Foundation

/// Debug builds only: plays a recorded clip into the SpeechAnalyzer engine in
/// place of the microphone, at the clip's own pace, so a machine without a
/// microphone (a fleet Mac mini) can record dictation through the real
/// engine, session, bridge and composer. Only the audio source differs.
///
/// `CMUX_NEXT_DICTATION_AUDIO_FILE=/path/to/clip.m4a` selects it. Release
/// builds compile none of this: every piece of it, here and at its call
/// sites, is inside `#if DEBUG`.
public enum RecordedDictationInput {
    /// The environment variable naming the clip.
    public static let environmentKey = "CMUX_NEXT_DICTATION_AUDIO_FILE"

    /// The clip `environment` names, if any.
    public static func url(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Feeds the clip to `ingest` in tap-sized buffers at real-time pace,
    /// and to the level meter as the tap would. Ends at the end of the clip
    /// (the session keeps listening to silence until stopped) or on cancel.
    static func play(
        _ url: URL, meter: DictationAudioLevelMeter?, ingest: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws -> Task<Void, Never> {
        let reader = try RecordedFileReader(AVAudioFile(forReading: url))
        let sampleRate = reader.sampleRate
        let frames: AVAudioFrameCount = 4096
        let pace = Duration.seconds(Double(frames) / sampleRate)
        // task-owner: stored by the engine as its audio source; cancelled when capture stops
        return Task {
            var position: AVAudioFramePosition = 0
            while !Task.isCancelled, let buffer = reader.next(frames) { // wakeup-allow: debug-only clip playback, ends with the clip or the session
                meter?.record(buffer)
                ingest(buffer, AVAudioTime(sampleTime: position, atRate: sampleRate))
                position += AVAudioFramePosition(buffer.frameLength)
                // wakeup-allow: debug-only clip playback paced like a microphone tap (about 12 per second while dictating)
                try? await Task.sleep(for: pace)
            }
        }
    }
}

extension SpeechAnalyzerDictationTranscriber {
    /// Hear `url` instead of the microphone; call before ``transcribe(locale:)``.
    func hear(_ url: URL) { recordedInput = url }

    func playRecordedInput(_ url: URL) throws {
        let box = inputBox
        recordedPlayback = try RecordedDictationInput.play(url, meter: levelMeter) { box.ingest($0, at: $1) }
    }
}

/// One reader per playback; only the playback task touches it.
private final class RecordedFileReader: @unchecked Sendable {
    private let file: AVAudioFile
    let sampleRate: Double

    init(_ file: AVAudioFile) {
        self.file = file
        sampleRate = file.processingFormat.sampleRate
    }

    func next(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil, buffer.frameLength > 0 else { return nil }
        return buffer
    }
}

/// With a recorded clip there is no microphone to ask for.
public struct RecordedInputAuthorizer: DictationAuthorizing {
    public init() {}
    public func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    public func requestMicrophoneAuthorization() async -> Bool { true }
    public func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    public func requestSpeechRecognitionAuthorization() async -> Bool { true }
}
#endif
