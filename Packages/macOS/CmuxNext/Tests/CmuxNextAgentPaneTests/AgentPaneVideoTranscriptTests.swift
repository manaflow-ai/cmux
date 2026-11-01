import AVFoundation
@testable import CmuxNextAgentPane
import Foundation
import Speech
import Testing

/// Leo, 2026-11-01, after the agent saw only sampled frames of a recording: "i feel like
/// cmux-next should give u better tools to deal with this kind of thing". An attached video's
/// speech is transcribed on this Mac, with timestamps, for the agent (``AgentPaneVideoTranscript``,
/// `video.transcript`): never with a prompt or a download, bounded in length and time, and nothing
/// for audio with no speech in it.
@MainActor @Suite(.serialized)
struct AgentPaneVideoTranscriptTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `seconds` of silence as an AAC `.m4a` at `url`.
    nonisolated private static func silence(at url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
    }

    /// A one-second H.264 movie with no audio track.
    nonisolated private static func silentMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<5 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
            #expect(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 5)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// The synthesizer's buffers, written to a file as they come (on the synthesizer's own queue, one at a time).
    private final class SpeechSink: @unchecked Sendable {
        let url: URL
        var file: AVAudioFile?
        init(url: URL) { self.url = url }
    }

    /// `text` spoken by the system voice into a file at `url`; false when this Mac has no voice to speak it.
    nonisolated private static func speech(_ text: String, at url: URL) async -> Bool {
        guard let voice = AVSpeechSynthesisVoice(language: "en-US") else { return false }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let sink = SpeechSink(url: url)
        let (done, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                sink.file = nil
                finished.finish()
                return
            }
            if sink.file == nil { sink.file = try? AVAudioFile(forWriting: sink.url, settings: pcm.format.settings) }
            try? sink.file?.write(from: pcm)
        }
        // A voice that never answers ends the wait.
        let limit = Task {
            try? await Task.sleep(for: .seconds(20))
            finished.finish()
        }
        for await _ in done {}
        limit.cancel()
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether an on-device engine may transcribe US English here without asking or downloading.
    nonisolated private static func engineReady() async -> Bool {
        if #available(macOS 26, *), let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if await AssetInventory.status(forModules: [transcriber]) == .installed { return true }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
            && SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func recognizedWordsBreakIntoLinesAtPausesAndLength() {
        let words: [(text: String, start: Double, end: Double)] = [
            ("open", 0.0, 0.3), ("the", 0.35, 0.4), ("settings", 0.45, 0.9),
            ("then", 2.5, 2.7), ("click", 2.75, 3.0),
        ]
        #expect(AgentPaneVideoTranscript.lines(words) == [
            .init(startMs: 0, endMs: 900, text: "open the settings"),
            .init(startMs: 2500, endMs: 3000, text: "then click"),
        ])
        let long = (0..<30).map { (text: "w\($0)", start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.1) }
        #expect(AgentPaneVideoTranscript.lines(long).map { $0.text.split(separator: " ").count } == [24, 6])
        #expect(AgentPaneVideoTranscript.lines([]).isEmpty)
    }

    @Test func aTranscriptNeedsWordsAndStaysInsideWhatWasHeard() throws {
        let make = { (segments: [AgentPaneVideoTranscript.Segment]) in
            AgentPaneVideoTranscript.transcript(segments, heardMs: 5000, durationMs: 9000, engine: .speechAnalyzer, locale: "en-US")
        }
        // A cough or a word of a song is no speech.
        #expect(make([.init(startMs: 0, endMs: 400, text: "  uh ")]) == nil)
        #expect(make([.init(startMs: 0, endMs: 400, text: " ")]) == nil)
        let transcript = try #require(make([
            .init(startMs: 4000, endMs: 6000, text: " and that is the bug "),
            .init(startMs: 0, endMs: 1200, text: "Here is the build."),
            .init(startMs: 1300, endMs: 1400, text: ""),
        ]))
        #expect(transcript.segments == [
            .init(startMs: 0, endMs: 1200, text: "Here is the build."),
            .init(startMs: 4000, endMs: 5000, text: "and that is the bug"),
        ])
        let reply = transcript.reply
        #expect(reply["heardMs"] as? Int == 5000 && reply["durationMs"] as? Int == 9000 && reply["engine"] as? String == "speechAnalyzer")
        #expect((reply["segments"] as? [[String: Any]])?.first?["text"] as? String == "Here is the build.")
        // A long transcript is cut at whole segments, under the hidden context's budget.
        let many = (0..<2000).map { AgentPaneVideoTranscript.Segment(startMs: $0, endMs: $0 + 1, text: "one two three four five six seven eight") }
        let cut = try #require(make(many))
        #expect(cut.segments.count < many.count)
        #expect(cut.segments.reduce(0) { $0 + $1.text.utf8.count } <= AgentPaneVideoTranscript.maximumTextBytes)
    }

    @Test func noAudioOrOnlySilenceGivesNoTranscript() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("screen.mov")
        try await Self.silentMovie(at: movie)
        #expect(await AgentPaneVideoTranscript.read(movie) == nil)
        let quiet = folder.appendingPathComponent("quiet.m4a")
        try Self.silence(at: quiet, seconds: 3)
        #expect(await AgentPaneVideoTranscript.read(quiet) == nil)
        let fake = folder.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: fake)
        #expect(await AgentPaneVideoTranscript.read(fake) == nil)
        #expect(await AgentPaneVideoTranscript.read(folder) == nil)
    }

    @Test func spokenWordsComeBackWithTheirTimesWhenAnEngineMayRun() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("spoken.caf")
        let said = "The quick brown fox jumps over the lazy dog. Please open the settings window."
        guard await Self.speech(said, at: clip) else { return }
        let ready = await Self.engineReady()
        let started = ContinuousClock.now
        let transcript = await AgentPaneVideoTranscript.read(clip, locale: Locale(identifier: "en-US"))
        guard ready else {
            // No model installed and no permission granted: nothing asked, nothing downloaded, no transcript.
            #expect(transcript == nil)
            return
        }
        let heard = try #require(transcript, "an on-device engine is ready but gave no transcript")
        let text = heard.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("fox") || text.contains("settings"), "\(text)")
        #expect(heard.segments.allSatisfy { $0.startMs <= $0.endMs && $0.endMs <= heard.heardMs })
        #expect(heard.segments.map(\.startMs) == heard.segments.map(\.startMs).sorted())
        #expect(ContinuousClock.now - started < .seconds(30))
        // A budget that runs out first gives nothing, and returns at once.
        let rushed = ContinuousClock.now
        #expect(await AgentPaneVideoTranscript.read(clip, locale: Locale(identifier: "en-US"), budget: .zero) == nil)
        #expect(ContinuousClock.now - rushed < .seconds(5))
    }

    @Test func theHostTranscribesOnlyAVideoOfAChatOnThisMacInsideItsFoldersOrHome() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let clip = desktop.appendingPathComponent("Screen Recording.mov")
        try await Self.silentMovie(at: clip)
        let outside = folder.appendingPathComponent("outside.mov")
        try FileManager.default.copyItem(at: clip, to: outside)
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.home = home.path
        let videos = folder.appendingPathComponent("videos", isDirectory: true)
        model.replyLinks.videoFolder = videos

        // A video with no speech answers no segments; its copy is gone after.
        let reply = await Self.ask(model, "video.transcript", ["src": clip.path])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(((reply["value"] as? [String: Any])?["segments"] as? [Any])?.isEmpty == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []).isEmpty)
        // Outside home and the folders, or a chat on another machine: refused.
        #expect(Self.errorCode(await Self.ask(model, "video.transcript", ["src": outside.path])) == AgentPaneReplyError.mediaRefused.rawValue)
        model.remoteChat = true
        #expect(Self.errorCode(await Self.ask(model, "video.transcript", ["src": clip.path])) == AgentPaneReplyError.mediaRefused.rawValue)
    }

    @Test func theRequestTakesOnlyItsSourceAndIsPassive() {
        #expect(AgentPaneReplyRequest(method: "video.transcript", params: ["src": "/a.mov"]) == .videoTranscript("/a.mov"))
        #expect(AgentPaneReplyRequest(method: "video.transcript", params: ["src": "/a.mov", "seconds": 9]) == nil)
        #expect(AgentPaneReplyRequest(method: "video.transcript", params: [:]) == nil)
        #expect(AgentPaneReplyRequest.videoTranscript("/a.mov").isPassive)
        #expect(AgentPageOps.method(for: "cmux.agent.video.transcript") == "video.transcript")
    }
}
