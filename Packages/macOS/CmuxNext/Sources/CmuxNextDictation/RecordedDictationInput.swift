#if DEBUG || CMUX_BENCH_HOOKS
import AVFoundation
public import CmuxNextWakeups
import Foundation

/// Debug builds only: plays a recorded clip into the SpeechAnalyzer engine in
/// place of the microphone, at the clip's own pace, so a machine without a
/// microphone (a fleet Mac mini) can record dictation through the real
/// engine, session, bridge and composer. Only the audio source differs.
///
/// `CMUX_NEXT_DICTATION_AUDIO_FILE=/path/to/clip.m4a` selects it. Release
/// builds compile none of this: every piece of it, here and at its call
/// sites, is inside `#if DEBUG`.
enum RecordedDictationInput {
    /// The environment variable naming the clip.
    static let environmentKey = "CMUX_NEXT_DICTATION_AUDIO_FILE"

    /// The clip `environment` names, if any.
    static func url(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
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
            let tolerance = WakeLeeway.window(delay: pace).tolerance
            while !Task.isCancelled, let buffer = reader.next(frames) { // wakeup-allow: debug clip playback, ends with the clip or the session
                meter?.record(buffer)
                let start = position
                position += AVAudioFramePosition(buffer.frameLength)
                // The last use of `buffer` here: `ingest` moves it to the conversion worker.
                ingest(buffer, AVAudioTime(sampleTime: start, atRate: sampleRate))
                // wakeup-allow: debug clip playback paced like a microphone tap (about 12 per second while dictating)
                // timer-class-allow: off-main, Debug builds only: the clip's pace stands in for the microphone tap's; no main-thread job
                try? await Task.sleep(for: pace, tolerance: tolerance)
            }
        }
    }
}

@available(macOS 26, *)
extension SpeechAnalyzerDictationTranscriber {
    /// Hear `url` instead of the microphone; call before ``transcribe(locale:)``.
    func hear(_ url: URL) { recordedInput = url }

    func playRecordedInput(_ url: URL) throws {
        let box = inputBox
        recordedPlayback = try RecordedDictationInput.play(url, meter: levelMeter) { box.ingest($0, at: $1) }
    }
}

/// One reader per playback. Not Sendable: ``RecordedDictationInput/play(_:meter:ingest:)``
/// sends it into the playback task, the only code that touches it after that.
private final class RecordedFileReader {
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

extension DictationSession {
    /// A session that hears the clip `CMUX_NEXT_DICTATION_AUDIO_FILE` names
    /// through the on-device engine, or nil when it names none. `deadlines` is the app's
    /// (`AppServices.mainDeadlines`), as for any session.
    public static func recorded(deadlines: MainDeadlineScheduler) -> DictationSession? {
        recorded(in: ProcessInfo.processInfo.environment, deadlines: deadlines)
    }

    static func recorded(in environment: [String: String], deadlines: MainDeadlineScheduler) -> DictationSession? {
        guard let clip = RecordedDictationInput.url(in: environment) else { return nil }
        return DictationSession(deadlines: deadlines, authorizer: RecordedInputAuthorizer(), makeTranscriber: { meter in
            OnDeviceDictationTranscriber(levelMeter: meter, recordedInput: clip)
        })
    }
}

/// With a recorded clip there is no microphone to ask for.
struct RecordedInputAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}
#endif
