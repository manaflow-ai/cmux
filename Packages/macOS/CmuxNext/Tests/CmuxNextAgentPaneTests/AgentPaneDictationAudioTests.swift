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

    @Test func aRecordingIsSixteenKilohertzMonoWAV() throws {
        let recording = DictationAudioRecording()
        // One second at 48 kHz: a constant half-scale signal.
        let input = [Float](repeating: 0.5, count: 48_000)
        input.withUnsafeBufferPointer { recording.append($0, sampleRate: 48_000) }
        let wav = try #require(recording.wav())
        #expect(wav.count == 44 + 16_000 * 2)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        let field = { (at: Int, size: Int) in wav[at..<(at + size)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        #expect(field(22, 2) == 1) // channels
        #expect(field(24, 4) == 16_000) // sample rate
        #expect(field(34, 2) == 16) // bits per sample
        #expect(field(40, 4) == 16_000 * 2) // data bytes
        #expect(field(44, 2) == Int(Int16(0.5 * Float(Int16.max))))
    }

    @Test func aRecordingPastTheLimitGoesAsTextAlone() {
        let recording = DictationAudioRecording()
        let second = [Float](repeating: 0.1, count: 16_000)
        for _ in 0...Int(DictationAudioRecording.maximumDuration) {
            second.withUnsafeBufferPointer { recording.append($0, sampleRate: 16_000) }
        }
        #expect(recording.wav() == nil)
        #expect(DictationAudioRecording().wav() == nil)
    }

    @Test func theLastUpdateCarriesTheRecordingToThePage() throws {
        let audio = Data("RIFF".utf8)
        let payload = AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build", audio: audio))
        let sent = try #require(payload["audio"] as? [String: any Sendable])
        #expect(sent["mimeType"] as? String == "audio/wav")
        #expect(sent["data"] as? String == audio.base64EncodedString())
        #expect(AgentPaneDictation.payload(DictationUpdate(phase: .idle, text: "fix the build"))["audio"] == nil)
    }
}
