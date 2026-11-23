import AVFoundation
@testable import CmuxNextDictation
import Foundation
import Testing

/// cmux's own dictation with the person's own provider (`agentPane.dictationEngine`): the engine
/// records while listening, has the provider transcribe the WAV on stop, inserts its text as one
/// final, and removes the WAV on every path. Leo, 2026-11-22: "people should be able to add their
/// own api keys/whatever and toggle that voice mode and whatever to link up to their provider of
/// choice. just like our mic thing."
@Suite
@MainActor
struct RecordedDictationTranscriberTests {
    @Test func theProviderTextIsOneFinal() async throws {
        let folder = Self.folder()
        let capture = ScriptedCapture()
        let calls = ProviderCalls()
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { audio, locale in
            await calls.add(audio, locale)
            return "  hello world \n"
        }, capture: capture, recordingFolder: folder)
        let stream = try await engine.transcribe(locale: Locale(identifier: "de-DE"))
        await capture.speak(seconds: 2)
        await engine.finishTranscribing()
        #expect(try await Self.events(stream) == [.final("hello world")])
        let sent = await calls.audio
        #expect(sent.count == 1)
        #expect(sent.first?.data != nil, "a short recording goes as its bytes")
        #expect(await calls.locales == ["de-DE"])
        #expect(await capture.stopped)
        try await Self.waitFor { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aProviderErrorFailsTheSession() async throws {
        let folder = Self.folder()
        let capture = ScriptedCapture()
        let session = DictationSession(authorizer: ProviderTestAuthorizer(), makeTranscriber: { meter in
            RecordedDictationTranscriber(levelMeter: meter, transcribe: { _, _ in
                throw DictationFailure.providerFailed(code: "key_invalid", detail: "")
            }, capture: capture, recordingFolder: folder)
        })
        session.start()
        try await Self.waitFor { session.phase == .listening }
        await capture.speak(seconds: 1)
        session.stop()
        try await Self.waitFor { session.phase.isStartable }
        #expect(session.phase == .failed(.providerFailed(code: "key_invalid", detail: "")))
        try await Self.waitFor { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aStopWaitsForTheProviderNotTheOnDeviceFlush() async throws {
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { _, _ in "" }, capture: ScriptedCapture())
        #expect(engine.finalizingDeadline == RecordedDictationTranscriber.providerDeadline)
        #expect(RecordedDictationTranscriber.providerDeadline > .seconds(60))
    }

    @Test func aCancelSendsNothingAndRemovesTheFile() async throws {
        let folder = Self.folder()
        let capture = ScriptedCapture()
        let calls = ProviderCalls()
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { audio, locale in
            await calls.add(audio, locale)
            return "never"
        }, capture: capture, recordingFolder: folder)
        let stream = try await engine.transcribe(locale: Locale(identifier: "en-US"))
        // Two seconds: the first one reaches the file.
        await capture.speak(seconds: 2)
        let file = folder.appending(path: "Recording.wav")
        try await Self.waitFor { FileManager.default.fileExists(atPath: file.path) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        await engine.cancelTranscribing()
        #expect(try await Self.events(stream).isEmpty)
        await engine.finishTranscribing()
        #expect(await calls.audio.isEmpty)
        #expect(await capture.stopped)
        try await Self.waitFor { !FileManager.default.fileExists(atPath: folder.path) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func nothingHeardEndsWithNoTextAndNoError() async throws {
        let calls = ProviderCalls()
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { audio, locale in
            await calls.add(audio, locale)
            return "never"
        }, capture: ScriptedCapture(), recordingFolder: Self.folder())
        let stream = try await engine.transcribe(locale: Locale(identifier: "en-US"))
        await engine.finishTranscribing()
        #expect(try await Self.events(stream).isEmpty)
        #expect(await calls.audio.isEmpty)
    }

    @Test func narrowbandInputIsACaptureFailure() async throws {
        let capture = ScriptedCapture()
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { _, _ in "never" },
                                                  capture: capture, recordingFolder: Self.folder())
        let stream = try await engine.transcribe(locale: Locale(identifier: "en-US"))
        await capture.speak(seconds: 1, rate: 8_000)
        await engine.finishTranscribing()
        await #expect(throws: DictationFailure.audioCaptureFailed("narrowband")) {
            _ = try await Self.events(stream)
        }
    }

    @Test func aFinishBeforeTheStartNeverOpensTheMicrophone() async throws {
        let capture = ScriptedCapture()
        let engine = RecordedDictationTranscriber(levelMeter: nil, transcribe: { _, _ in "never" },
                                                  capture: capture, recordingFolder: Self.folder())
        await engine.finishTranscribing()
        await #expect(throws: CancellationError.self) {
            _ = try await engine.transcribe(locale: Locale(identifier: "en-US"))
        }
        #expect(await capture.started == false)
    }

    /// A fresh folder under the temporary folder, not made yet: the recording makes and removes it.
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "recorded-dictation-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func events(_ stream: AsyncThrowingStream<DictationTranscriptionEvent, any Error>) async throws -> [DictationTranscriptionEvent] {
        var all: [DictationTranscriptionEvent] = []
        for try await event in stream { all.append(event) }
        return all
    }

    /// Polls `ready` on the main actor for up to 3 s.
    private static func waitFor(_ ready: () -> Bool) async throws {
        for _ in 0..<300 where !ready() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private nonisolated struct ProviderTestAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

/// The microphone, scripted: ``speak(seconds:rate:)`` hands the engine a steady tone.
private actor ScriptedCapture: DictationAudioCapturing {
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DictationFailure) async -> Void
    ) async throws {
        started = true
        sink = onBuffer
    }

    func stop() async {
        sink = nil
        stopped = true
    }

    func speak(seconds: Int, rate: Double = 16_000) {
        guard let sink, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let frames = AVAudioFrameCount(rate)
        for _ in 0..<seconds {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let samples = buffer.floatChannelData else { return }
            buffer.frameLength = frames
            samples[0].initialize(repeating: 0.5, count: Int(frames))
            sink(buffer)
        }
    }
}

/// What the provider was sent.
private actor ProviderCalls {
    private(set) var audio: [DictationAudio] = []
    private(set) var locales: [String] = []

    func add(_ audio: DictationAudio, _ locale: Locale) {
        self.audio.append(audio)
        locales.append(locale.identifier)
    }
}
