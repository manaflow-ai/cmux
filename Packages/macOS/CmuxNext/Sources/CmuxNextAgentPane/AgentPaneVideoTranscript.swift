import AVFoundation
import CmuxNextWakeups
import CoreMedia
import Foundation
import Speech

/// The speech in an attached video, transcribed on this Mac with timestamps (`video.transcript`),
/// for the agent, which sees a video's key frames but cannot hear it. Leo, 2026-11-01, after the
/// agent saw only sampled frames of a 16 s recording: "i feel like cmux-next should give u better
/// tools to deal with this kind of thing".
///
/// Recognition stays on this Mac: SpeechAnalyzer's SpeechTranscriber on macOS 26 and later, when
/// the language's model is already installed (it is never downloaded for this), else
/// `SFSpeechRecognizer` with on-device recognition required, only when speech recognition is
/// already allowed. Nothing here asks the person for anything: when either would need a prompt
/// or a download, the video goes without a transcript. Only the first ``maximumSeconds`` are
/// heard, and a read that runs past ``budget`` gives nothing. Audio with no speech in it (silence,
/// music without words) gives nothing either (``minimumWords``).
nonisolated enum AgentPaneVideoTranscript {
    /// How much of a video is heard.
    static let maximumSeconds: Double = 10 * 60
    /// The longest a read may take before it gives up; the page's send waits much less for it
    /// (videoAttachments.ts) and goes without a transcript that is not there yet.
    static let budget: Duration = .seconds(60)
    /// Fewer words than this is no speech: a cough, a word of a song, a recognizer's guess at noise.
    static let minimumWords = 3
    /// The longest transcript text kept; the agent gets it as the prompt's hidden context
    /// (acpmux `prompt_context::MAX_BYTES` is 16 KiB for all of it).
    static let maximumTextBytes = 12 * 1024

    struct Segment: Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    enum Engine: String, Sendable {
        case speechAnalyzer
        case speechRecognizer
    }

    struct Transcript: Equatable, Sendable {
        var segments: [Segment]
        /// How much of the video was heard, in milliseconds (``maximumSeconds`` at most).
        var heardMs: Int
        var durationMs: Int
        var engine: Engine
        var locale: String

        /// The page's answer.
        var reply: [String: Any] {
            [
                "segments": segments.map { ["startMs": $0.startMs, "endMs": $0.endMs, "text": $0.text] },
                "heardMs": heardMs, "durationMs": durationMs, "engine": engine.rawValue, "locale": locale,
            ]
        }
    }

    /// The speech in the video at `file` (a regular file), or nil: no audio track, no speech, no
    /// on-device engine that may run without asking, or past ``budget``.
    @concurrent static func read(_ file: URL, locale: Locale = .current, budget: Duration = budget) async -> Transcript? {
        let outcome = FirstOutcome<Transcript?>()
        let work = Task(priority: .utility) { outcome.resolve(await transcribe(file, locale: locale)) }
        let deadline = DemandTimer(owner: "agent-pane.video-transcript")
        deadline.schedule(after: budget) {
            work.cancel()
            outcome.resolve(nil)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            work.cancel()
            outcome.resolve(nil)
        }
    }

    /// The video's audio, heard by the first engine that may run.
    static func transcribe(_ file: URL, locale: Locale) async -> Transcript? {
        guard AgentPaneVideoInfo.isRegularFile(file) else { return nil }
        let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let heard = min(duration.seconds, maximumSeconds)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: heard, preferredTimescale: 600))
        let durationMs = Int((duration.seconds * 1000).rounded()), heardMs = Int((heard * 1000).rounded())
        if #available(macOS 26, *), let found = await AnalyzerEngine.transcribe(asset: asset, track: track, range: range, locale: locale) {
            return transcript(found.segments, heardMs: heardMs, durationMs: durationMs, engine: .speechAnalyzer, locale: found.locale)
        }
        guard !Task.isCancelled,
              let found = await RecognizerEngine.transcribe(asset: asset, track: track, range: range, locale: locale) else { return nil }
        return transcript(found.segments, heardMs: heardMs, durationMs: durationMs, engine: .speechRecognizer, locale: found.locale)
    }

    /// `segments` cleaned (trimmed, empty ones dropped, inside the heard range, cut to
    /// ``maximumTextBytes``) as a transcript, or nil when they hold fewer than ``minimumWords``.
    static func transcript(_ segments: [Segment], heardMs: Int, durationMs: Int, engine: Engine, locale: String) -> Transcript? {
        var kept: [Segment] = []
        var bytes = 0
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            bytes += text.utf8.count + 16
            guard bytes <= maximumTextBytes else { break }
            let start = min(max(segment.startMs, 0), heardMs)
            kept.append(Segment(startMs: start, endMs: min(max(segment.endMs, start), heardMs), text: text))
        }
        let words = kept.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        guard words >= minimumWords else { return nil }
        return Transcript(segments: kept, heardMs: heardMs, durationMs: durationMs, engine: engine, locale: locale)
    }

    /// Words of `SFSpeechRecognizer`'s transcription grouped into lines: a new line after a pause
    /// of ``linePause`` or ``lineWords`` words.
    static let linePause = 1.0
    static let lineWords = 24

    static func lines(_ words: [(text: String, start: Double, end: Double)]) -> [Segment] {
        var out: [Segment] = []
        var current: [String] = []
        var start = 0.0, end = 0.0
        func flush() {
            guard !current.isEmpty else { return }
            out.append(Segment(startMs: Int((start * 1000).rounded()), endMs: Int((end * 1000).rounded()), text: current.joined(separator: " ")))
            current = []
        }
        for word in words {
            if !current.isEmpty, word.start - end >= linePause || current.count >= lineWords { flush() }
            if current.isEmpty { start = word.start }
            current.append(word.text)
            end = max(end, word.end)
        }
        flush()
        return out
    }

    /// Reads the audio of `track` within `range` as PCM buffers in `format`, handing each to `body`
    /// with its start time; stops early when the task is cancelled or `body` says so. False when the
    /// track could not be read.
    static func readAudio(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, format: AVAudioFormat,
                          _ body: (AVAudioPCMBuffer, CMTime) -> Bool) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        reader.timeRange = range
        let bits = switch format.commonFormat {
        case .pcmFormatInt16: 16
        case .pcmFormatFloat64: 64
        default: 32
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { if reader.status == .reading { reader.cancelReading() } }
        // Ends at the range's end (no next sample), on a cancel, or when `body` stops it.
        while let sample = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else { break }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
                continue
            }
            guard body(buffer, CMSampleBufferGetPresentationTimeStamp(sample)) else { break }
        }
        return reader.status != .failed
    }
}

/// SpeechAnalyzer with SpeechTranscriber (macOS 26): fast, on device, and asks for no permission.
/// Only a language whose model is already installed is used; a model is never downloaded here.
@available(macOS 26, *)
private nonisolated enum AnalyzerEngine {
    /// The most read buffers that may wait for the analyzer. Reading runs ahead of recognition, so
    /// the queue holds most of the heard audio; it is bounded by ``AgentPaneVideoTranscript/maximumSeconds``
    /// (ten minutes of 16 kHz mono is about 20 MB) and this cap, which is above ten minutes of
    /// 1024-frame buffers at 48 kHz. A buffer past it ends the read (`feedAudio`).
    static let queuedBuffers = 32_768

    static func transcribe(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, locale: Locale)
        async -> (segments: [AgentPaneVideoTranscript.Segment], locale: String)? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        // Another session of this app (dictation) may hold the locale already; release only our own.
        let reserved = (try? await AssetInventory.reserve(locale: supported)) == true
        defer { if reserved { Task { _ = await AssetInventory.release(reservedLocale: supported) } } }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(bufferingPolicy: .bufferingOldest(queuedBuffers))
        return await withTaskCancellationHandler {
            async let heard: [AgentPaneVideoTranscript.Segment]? = collect(transcriber)
            do {
                try await analyzer.start(inputSequence: input)
            } catch {
                feed.finish()
                await analyzer.cancelAndFinishNow()
                _ = await heard
                return nil
            }
            let read = feedAudio(asset: asset, track: track, range: range, format: format, into: feed)
            feed.finish()
            if read, !Task.isCancelled, (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil {
                guard let segments = await heard, !Task.isCancelled else { return nil }
                return (segments, supported.identifier(.bcp47))
            }
            await analyzer.cancelAndFinishNow()
            _ = await heard
            return nil
        } onCancel: {
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Reads the audio into `feed`, off the main actor (the read task's own thread; AVAssetReader's
    /// reads are short file reads).
    static func feedAudio(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, format: AVAudioFormat,
                          into feed: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation) -> Bool {
        AgentPaneVideoTranscript.readAudio(asset: asset, track: track, range: range, format: format) { buffer, time in
            switch feed.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) {
            case .enqueued: return true
            // Past the cap (or the analyzer gone): the read ends there, and the transcript covers
            // what was queued.
            case .dropped, .terminated: return false
            @unknown default: return false
            }
        }
    }

    static func collect(_ transcriber: SpeechTranscriber) async -> [AgentPaneVideoTranscript.Segment]? {
        var segments: [AgentPaneVideoTranscript.Segment] = []
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                let start = result.range.start.seconds, end = result.range.end.seconds
                guard start.isFinite, end.isFinite else { continue }
                segments.append(.init(startMs: Int((start * 1000).rounded()), endMs: Int((end * 1000).rounded()), text: text))
            }
        } catch {
            return nil
        }
        return segments
    }
}

/// `SFSpeechRecognizer`, on device only, for a system before macOS 26 or a language SpeechAnalyzer
/// has no installed model for. It runs only when speech recognition is already allowed: it never
/// shows the system prompt, so a person who never allowed it sees nothing.
private nonisolated enum RecognizerEngine {
    static func transcribe(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, locale: Locale)
        async -> (segments: [AgentPaneVideoTranscript.Segment], locale: String)? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let outcome = FirstOutcome<[AgentPaneVideoTranscript.Segment]?>()
        // `cancel()` is the only call made on it off this task (the cancel handler), and the Speech
        // framework takes it from any thread.
        nonisolated(unsafe) let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
                let words = result.bestTranscription.segments.map {
                    (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                }
                outcome.resolve(AgentPaneVideoTranscript.lines(words))
            } else if error != nil {
                outcome.resolve(nil)
            }
        }
        return await withTaskCancellationHandler {
            let read = AgentPaneVideoTranscript.readAudio(asset: asset, track: track, range: range, format: format) { buffer, _ in
                request.append(buffer)
                return true
            }
            request.endAudio()
            guard read, !Task.isCancelled else {
                task.cancel()
                return nil
            }
            guard let segments = await outcome.value() else { return nil }
            return (segments, recognizer.locale.identifier(.bcp47))
        } onCancel: {
            task.cancel()
            outcome.resolve(nil)
        }
    }
}

extension AgentPaneModel {
    /// `video.transcript {src}`: the speech in an attached video (``AgentPaneVideoTranscript``),
    /// read from its private copy (``videoSnapshot(_:)``, the same checks as `video.info`), which
    /// is then removed. A video with no speech, or none that may be heard without asking, answers
    /// `{segments: []}`, which the page treats as no transcript.
    func videoTranscript(_ src: String) async -> [String: Any] {
        guard let copy = await videoSnapshot(src) else { return Self.replyFailure(.mediaRefused) }
        let transcript = await AgentPaneVideoTranscript.read(copy)
        await AgentPaneVideoInfo.discard(copy)
        guard !chatIsElsewhere else { return Self.replyFailure(.mediaRefused) }
        return AgentPaneReply.success(transcript?.reply ?? ["segments": [Any]()])
    }
}
