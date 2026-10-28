import CmuxNextDictation
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
        #expect(audio.byteCount == 44 + 150 * 16_000 * 2)
        let file = try #require(audio.file)
        let wav = try Data(contentsOf: file)
        #expect(wav.count == audio.byteCount)
        let dataBytes = wav[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(dataBytes == 150 * 16_000 * 2, "the header names every sample")
        let expected = Int(Int16(0.1 * Float(Int16.max)))
        #expect(samples(wav).allSatisfy { abs($0 - expected) <= 1 })
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
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
