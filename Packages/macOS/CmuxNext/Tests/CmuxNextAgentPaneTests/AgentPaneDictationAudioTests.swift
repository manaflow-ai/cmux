@testable import CmuxNextDictation
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Voice input through the selected harness: when the chat's harness takes audio (ACP
/// `promptCapabilities.audio`), the page says so with `dictation.audio`, and each session keeps its
/// audio, 16 kHz mono 16-bit WAV, for the prompt.
@Suite
@MainActor
struct AgentPaneDictationAudioTests {
    @Test func thePageTurnsRecordingOnAndOff() {
        #expect(AgentPaneRequest(body: ["method": "dictation.audio", "params": ["enabled": true]]) == .dictation(.recordAudio(true)))
        #expect(AgentPaneRequest(body: ["method": "dictation.audio", "params": ["enabled": false]]) == .dictation(.recordAudio(false)))
        #expect(AgentPaneRequest(body: ["method": "dictation.audio"]) == .unsupported("dictation.audio"))
        #expect(AgentPageOps.methods["dictation.audio"] == "dictation.audio")
    }

    /// A recording into its own temporary folder; the folder goes with the test.
    private func recording() -> (DictationAudioRecording, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (DictationAudioRecording(folder: folder), folder)
    }

    private func feed(_ recording: DictationAudioRecording, seconds: Int, value: Float = 0.5, rate: Double = 16_000) {
        let second = [Float](repeating: value, count: Int(rate))
        for _ in 0..<seconds { second.withUnsafeBufferPointer { recording.append($0, sampleRate: rate) } }
    }

    private func samples(_ wav: Data) -> [Int] {
        stride(from: 44, to: wav.count - 1, by: 2).map { Int(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) }
    }

    @Test func aRecordingIsSixteenKilohertzMonoWAV() async throws {
        let (recording, folder) = recording()
        defer { try? FileManager.default.removeItem(at: folder) }
        // One second at 48 kHz: a constant half-scale signal.
        feed(recording, seconds: 1, rate: 48_000)
        let audio = try #require(await recording.finish())
        let wav = try #require(audio.data)
        #expect(audio.file == nil, "a short recording goes inline and its file is gone")
        #expect(wav.count == 44 + 16_000 * 2)
        #expect(audio.byteCount == wav.count)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        let field = { (at: Int, size: Int) in wav[at..<(at + size)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        #expect(field(22, 2) == 1) // channels
        #expect(field(24, 4) == 16_000) // sample rate
        #expect(field(34, 2) == 16) // bits per sample
        #expect(field(40, 4) == 16_000 * 2) // data bytes
        #expect(field(44, 2) == Int(Int16(0.5 * Float(Int16.max))))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? true)
    }

    /// 44.1 and 24 kHz are no whole multiple of 16 kHz; a level input must come out level, not
    /// amplitude-modulated by how the spans fall.
    @Test(arguments: [44_100.0, 24_000.0, 22_050.0, 16_000.0])
    func aLevelInputStaysLevelAtAnyRate(rate: Double) async throws {
        let (recording, folder) = recording()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(recording, seconds: 1, rate: rate)
        let wav = try #require(await recording.finish()?.data)
        let samples = samples(wav)
        #expect(abs(samples.count - 16_000) <= 1)
        let expected = Int(Int16(0.5 * Float(Int16.max)))
        #expect(samples.allSatisfy { abs($0 - expected) <= 1 })
    }

    @Test func narrowbandInputGoesAsTextAlone() async {
        let (recording, folder) = recording()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(recording, seconds: 1, rate: 8_000)
        #expect(await recording.finish() == nil)
        #expect(recording.omission == .narrowband)
        // A silent session has nothing to send, and nothing left out.
        let (silent, other) = self.recording()
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(await silent.finish() == nil)
        #expect(silent.omission == nil)
    }

    /// Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE". A session
    /// over two minutes lost its whole recording (`tooLong`); the prompt got the transcript only.
    /// Now any length is kept, written to its file a second at a time, and goes as that file.
    @Test func aRecordingOverTwoMinutesIsKept() async throws {
        let (recording, folder) = recording()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(recording, seconds: 150, value: 0.1)
        let audio = try #require(await recording.finish())
        #expect(recording.omission == nil)
        #expect(audio.data == nil, "past the inline budget the recording goes as its file")
        let headerBytes = DictationAudioRecording.headerBytes
        #expect(audio.byteCount == headerBytes + 150 * 16_000 * 2)
        let file = try #require(audio.file)
        let wav = try Data(contentsOf: file)
        #expect(wav.count == audio.byteCount)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[(headerBytes - 8)..<(headerBytes - 4)], as: UTF8.self) == "data")
        let dataBytes = wav[(headerBytes - 4)..<headerBytes].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(dataBytes == 150 * 16_000 * 2, "the header names every sample")
        let expected = Int(Int16(0.1 * Float(Int16.max)))
        let fileSamples = stride(from: headerBytes, to: wav.count - 1, by: 2).map { Int(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) }
        #expect(fileSamples.allSatisfy { abs($0 - expected) <= 1 })
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// A finish queued behind a tap's flush: the header counts every sample and the file holds
    /// them all, and no write opens a second file after the close. The writer is held so the flush
    /// and the finish queue up in that order.
    @Test func aFinishQueuedBehindAFlushKeepsEverySample() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = DictationAudioRecording(folder: folder)
        recording.writer.suspend()
        // Exactly one second: this append queues one flush.
        feed(recording, seconds: 1, value: 0.25)
        let finishing = Task { await recording.finish() }
        recording.writer.resume()
        let audio = try #require(await finishing.value)
        let wav = try #require(audio.data)
        let dataBytes = wav[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(dataBytes == 16_000 * 2, "the header counts every sample")
        #expect(wav.count == 44 + dataBytes, "and the file holds every sample it counts")
        // A finish of an ended recording answers after everything queued before it: nothing is left behind.
        #expect(await recording.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Review of #26559 at 2596b7ca: a recording's file went to a shared temporary folder that
    /// nothing cleaned. A recording owns the folder it is given (an upload folder of the chat, which
    /// goes with the chat or after 30 days): a short one sent inline, or a discarded one, leaves no
    /// folder; a long one is `Recording.wav` in it.
    @Test func aRecordingOwnsItsFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let shortFolder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let short = DictationAudioRecording(folder: shortFolder)
        feed(short, seconds: 1)
        #expect(try #require(await short.finish()).data != nil)
        #expect(!FileManager.default.fileExists(atPath: shortFolder.path), "a recording sent inline leaves no folder")
        let discardedFolder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let discarded = DictationAudioRecording(folder: discardedFolder)
        feed(discarded, seconds: 2)
        discarded.discard()
        #expect(await discarded.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: discardedFolder.path), "a discarded recording leaves no folder")
        let longFolder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let long = DictationAudioRecording(folder: longFolder)
        feed(long, seconds: 140)
        let longAudio = try #require(await long.finish())
        let file = try #require(longAudio.file)
        #expect(file == longFolder.appending(path: "Recording.wav"))
        // The file is named by what the writer left there, so a file put at that path later is not it.
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        defer { close(descriptor) }
        #expect(longAudio.fileIdentity != nil)
        #expect(longAudio.fileIdentity == DictationFileIdentity.of(descriptor: descriptor))
    }

    /// Review of #26559 at 78df61f4: a finish after a discard answered at once, before the
    /// discard's delete ran on the writer queue, so a caller (and these tests) could see the
    /// folder still there. A finish answers only after every step queued before it: with the writer
    /// held, the finish cannot answer before the delete, whatever the scheduler does.
    @Test func aFinishAfterADiscardWaitsForItsDelete() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let recording = DictationAudioRecording(folder: folder)
        feed(recording, seconds: 2)
        await withCheckedContinuation { done in recording.writer.async { done.resume() } }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        recording.writer.suspend()
        recording.discard()
        let finishing = Task {
            let audio = await recording.finish()
            return (audio, FileManager.default.fileExists(atPath: folder.path))
        }
        recording.writer.resume()
        let (audio, folderThere) = await finishing.value
        #expect(audio == nil)
        #expect(!folderThere, "the finish answered after the discard's delete")
    }

    /// Review of #26559 at 90725635 (P1): discard marked the recording finished under the lock and
    /// queued its delete after releasing it, so a finish racing it on another thread could queue
    /// its answer first and return with the folder still there. Many real races, no hook: every
    /// finish that answers after (or alongside) a discard sees the folder gone.
    @Test func aFinishRacingADiscardStillWaitsForTheDelete() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        for _ in 0..<200 {
            let folder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            let recording = DictationAudioRecording(folder: folder)
            feed(recording, seconds: 1)
            await withCheckedContinuation { done in recording.writer.async { done.resume() } }
            async let discarded: Void = Task.detached { recording.discard() }.value
            async let raced = Task.detached { () -> Bool? in
                // A finish that wins the race closes the recording itself: it says nothing here.
                let audio = await recording.finish()
                return audio == nil ? FileManager.default.fileExists(atPath: folder.path) : nil
            }.value
            _ = await discarded
            if let folderThere = await raced { #expect(!folderThere, "a finish after a discard answered before the delete") }
        }
    }

    /// Review of #26559 at 90725635 (P3): the WAV header stored the data length in 32 bits, so a
    /// recording past 4 GiB (about 37 hours) left a clamped, invalid header. Past 4 GiB the file
    /// is RF64: the same 16 kHz mono PCM with 64-bit sizes in a ds64 chunk, and the samples stay
    /// where they began.
    @Test func aRecordingPast4GiBHasAnRF64Header() throws {
        let field = { (data: Data, at: Int, size: Int) in data[at..<(at + size)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        let small = DictationAudioRecording.header(samples: 16_000)
        #expect(String(decoding: small.prefix(4), as: UTF8.self) == "RIFF")
        let samples = 2_500_000_000 // 5 GB of data
        let big = DictationAudioRecording.header(samples: samples)
        #expect(big.count == small.count, "the samples start at the same offset whatever the size")
        #expect(String(decoding: big.prefix(4), as: UTF8.self) == "RF64")
        #expect(field(big, 4, 4) == 0xFFFF_FFFF)
        #expect(String(decoding: big[12..<16], as: UTF8.self) == "ds64")
        let dataBytes = samples * 2
        #expect(field(big, 28, 8) == dataBytes, "ds64 dataSize")
        #expect(field(big, 20, 8) == big.count - 8 + dataBytes, "ds64 riffSize")
        let dataAt = big.count - 8
        #expect(String(decoding: big[dataAt..<(dataAt + 4)], as: UTF8.self) == "data")
        #expect(field(big, dataAt + 4, 4) == 0xFFFF_FFFF)
    }

    /// Review of #26559 at 90725635 (P2): a cancel while a long recording was closing dropped only
    /// its WAV file, so its upload folder stayed (empty) until the 30-day sweep.
    @Test func aCancelWhileALongRecordingClosesLeavesNoFolder() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let engine = LongRecordingTranscriber(seconds: 140)
        let session = DictationSession(authorizer: GrantedDictationAuthorizer(), makeTranscriber: { meter in
            engine.meter = meter
            return engine
        })
        session.recordsAudio = true
        session.recordingFolder = { folder }
        session.start()
        try await waitFor { engine.fed && session.phase == .listening }
        let writer = try #require(session.recording?.writer)
        await withCheckedContinuation { done in writer.async { done.resume() } }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // The close waits on the held writer: the session sits in its closing step.
        writer.suspend()
        session.stop()
        try await waitFor { session.closing != nil }
        session.cancel()
        writer.resume()
        try await waitFor { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the cancelled recording's folder goes")
    }

    /// Review of #27012 (P2): a recording whose file could not be written (a full disk, a folder
    /// that is not writable) came back nil with no omission, so the session's last update said
    /// nothing and auto-send sent the transcript alone without a word. The loss is now an omission
    /// (`writeFailed`) the update carries to the page, which says the audio was lost.
    @Test func aRecordingThatCannotBeWrittenSaysItsAudioWasLost() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Short (inline) and long (its file) recordings alike: the folder's path is a regular file,
        // so neither the folder nor the WAV in it can be made.
        for seconds in [2, 140] {
            let folder = parent.appending(path: "blocked-\(seconds)")
            #expect(FileManager.default.createFile(atPath: folder.path, contents: Data()))
            let recording = DictationAudioRecording(folder: folder)
            feed(recording, seconds: seconds)
            #expect(await recording.finish() == nil)
            #expect(recording.omission == .writeFailed, "a recording of \(seconds) s")
        }
        // A discarded recording lost nothing the person wanted: no omission.
        let (discarded, other) = self.recording()
        defer { try? FileManager.default.removeItem(at: other) }
        feed(discarded, seconds: 2)
        discarded.discard()
        #expect(await discarded.finish() == nil)
        #expect(discarded.omission == nil)
        #expect(AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "t", audioOmitted: .writeFailed))["audioOmitted"] as? String == "writeFailed")
    }

    /// The session's last update carries a recording's write failure to the page.
    @Test func aSessionWhoseRecordingCannotBeWrittenSaysSoInItsLastUpdate() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appending(path: "blocked")
        #expect(FileManager.default.createFile(atPath: folder.path, contents: Data()))
        let engine = LongRecordingTranscriber(seconds: 3)
        let session = DictationSession(authorizer: GrantedDictationAuthorizer(), makeTranscriber: { meter in
            engine.meter = meter
            return engine
        })
        let updates = Updates()
        session.onUpdate = { updates.all.append($0) }
        session.recordsAudio = true
        session.recordingFolder = { folder }
        session.start()
        try await waitFor { engine.fed && session.phase == .listening }
        session.stop()
        try await waitFor { updates.all.last?.phase == .idle }
        let last = try #require(updates.all.last)
        #expect(last.phase == .idle)
        #expect(last.audio == nil)
        #expect(last.audioOmitted == .writeFailed)
    }

    @Test(arguments: [false, true])
    func aRecordingClosingAfterNavigationNamesItsOriginalChat(writeFails: Bool) async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        if writeFails {
            #expect(FileManager.default.createFile(atPath: parent.path, contents: Data()))
        }
        let engine = LongRecordingTranscriber(seconds: 1)
        let session = DictationSession(authorizer: GrantedDictationAuthorizer(), makeTranscriber: { meter in
            engine.meter = meter
            return engine
        })
        let updates = Updates()
        let pane = AgentPaneDictation(send: { updates.all.append($0) }, microphone: DictationMicrophone(), makeSession: { session })
        var chat = "chat-a"
        pane.chatSession = { chat }
        pane.recordingFolder = { parent }
        pane.handle(.recordAudio(true))
        pane.handle(.start)
        try await waitFor { engine.fed && session.phase == .listening }
        let recording = try #require(session.recording)
        recording.writer.suspend()
        pane.handle(.stop)
        try await waitFor { session.closing != nil }
        chat = "chat-b"
        recording.writer.resume()
        try await waitFor { updates.all.last?.phase == .idle }
        let update = try #require(updates.all.last)
        #expect(update.chat == "chat-a")
        if writeFails {
            #expect(update.audio == nil)
            #expect(update.audioOmitted == .writeFailed)
        } else {
            #expect(update.audio != nil)
        }
        let payload = AgentPaneDictation.payload(update)
        #expect(payload["session"] as? String == "chat-a")
    }

    /// The updates a session sent, in order.
    private final class Updates {
        var all: [DictationUpdate] = []
    }

    /// Polls `ready` on the main actor for up to 3 s.
    private func waitFor(_ ready: () -> Bool) async throws {
        for _ in 0..<300 where !ready() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aDiscardedRecordingLeavesNoFile() async throws {
        let (recording, folder) = recording()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(recording, seconds: 3)
        recording.discard()
        // The discard runs after the writes queued before it; a finish after it waits for both.
        #expect(await recording.finish() == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? true)
    }

    @Test func theLastUpdateCarriesTheRecordingToThePage() throws {
        let audio = Data("RIFF".utf8)
        let payload = AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build", audio: DictationAudio(byteCount: audio.count, data: audio)))
        let sent = try #require(payload["audio"] as? [String: any Sendable])
        #expect(sent["mimeType"] as? String == "audio/wav")
        #expect(sent["data"] as? String == audio.base64EncodedString())
        #expect(sent["path"] == nil)
        #expect(AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build"))["audio"] == nil)
    }

    @Test func aLongRecordingGoesToThePageAsItsFile() throws {
        let file = URL(filePath: "/tmp/cmux-dictation/Recording-a.wav")
        let payload = AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "a long one", audio: DictationAudio(file: file, byteCount: 9_600_044)))
        let sent = try #require(payload["audio"] as? [String: any Sendable])
        #expect(sent["path"] as? String == file.path)
        #expect(sent["byteCount"] as? Int == 9_600_044)
        #expect(sent["data"] == nil)
    }

    @Test func theLastUpdateSaysWhyTheRecordingWasLeftOut() {
        let payload = AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build", audioOmitted: .narrowband))
        #expect(payload["audioOmitted"] as? String == "narrowband")
        #expect(payload["audio"] == nil)
        #expect(AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build"))["audioOmitted"] == nil)
    }
}

private nonisolated struct GrantedDictationAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

/// An engine that hears `seconds` of level audio at its start (into the meter's recording) and
/// ends its stream when told to finish.
private nonisolated final class LongRecordingTranscriber: SpeechTranscribing, @unchecked Sendable {
    let seconds: Int
    var meter: DictationAudioLevelMeter?
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var heard = false
    var fed: Bool { lock.withLock { heard } }

    init(seconds: Int) { self.seconds = seconds }

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let second = [Float](repeating: 0.1, count: 16_000)
        for _ in 0..<seconds {
            second.withUnsafeBufferPointer { meter?.recording?.append($0, sampleRate: 16_000) }
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DictationTranscriptionEvent.self, throwing: (any Error).self)
        lock.withLock {
            self.continuation = continuation
            heard = true
        }
        return stream
    }

    func finishTranscribing() async {
        lock.withLock { continuation }?.finish()
    }
}
