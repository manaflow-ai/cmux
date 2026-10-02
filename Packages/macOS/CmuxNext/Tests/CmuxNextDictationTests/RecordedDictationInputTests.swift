#if DEBUG
import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import CmuxNextDictation

/// The Debug-only clip input that stands in for a microphone on fleet Macs.
@Suite struct RecordedDictationInputTests {
    @Test func theEnvironmentNamesTheClip() {
        #expect(RecordedDictationInput.url(in: [:]) == nil)
        #expect(RecordedDictationInput.url(in: [RecordedDictationInput.environmentKey: ""]) == nil)
        #expect(RecordedDictationInput.url(in: [RecordedDictationInput.environmentKey: "/tmp/clip.m4a"])?.path == "/tmp/clip.m4a")
    }

    /// Every frame of the clip reaches the engine, in order, and then the
    /// playback ends on its own.
    @Test func playsTheWholeClipThenEnds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames: AVAudioFrameCount = 6_000
        let tone = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        tone.frameLength = frames
        for index in 0..<Int(frames) { tone.floatChannelData![0][index] = sinf(Float(index) * 0.1) * 0.5 }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: tone)

        let heard = Mutex<[AVAudioFramePosition]>([])
        let meter = DictationAudioLevelMeter()
        let playback = try RecordedDictationInput.play(url, meter: meter) { buffer, time in
            heard.withLock { $0.append(time.sampleTime + AVAudioFramePosition(buffer.frameLength)) }
        }
        await playback.value
        // 4096 + 1904 frames: the second buffer starts where the first ended.
        #expect(heard.withLock { $0 } == [4_096, 6_000])
    }

    @Test func cancellingStopsPlayback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        silence.frameLength = 160_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence)

        let buffers = Mutex(0)
        let playback = try RecordedDictationInput.play(url, meter: nil) { _, _ in buffers.withLock { $0 += 1 } }
        // Partway through: two of the clip's 40 buffers played.
        await eventually("two buffers played") { buffers.withLock { $0 } >= 2 }
        let played = buffers.withLock { $0 }
        playback.cancel()
        await playback.value
        // Ten seconds of audio, but nothing past the buffer in flight was fed.
        #expect(buffers.withLock { $0 } <= played + 1)
    }
}
#endif
