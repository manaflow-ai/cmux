import AVFoundation
@testable import CmuxHomeCore
import Foundation
@testable import MessagesLabHome
import Testing

/// Audio messages in the Mac's Home (user, 2026-10-21: "audio messages dont
/// work on ios and dont send to macos"). An audio part showed as a file row
/// with a music note: no player, no waveform, no length.
@MainActor @Suite struct HomeAudioMessageTests {
    /// A 2 s mono WAV: a tone that swells and fades, then a second of near silence.
    static func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-audio-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<32_000 {
            let t = Double(i) / 16_000
            samples[i] = i < 16_000 ? Float(sin(2 * .pi * 220 * t) * 0.7 * sin(.pi * t)) : Float(sin(2 * .pi * 220 * t) * 0.002)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    static func ref(byteCount: Int = 64_000) -> AttachmentRef {
        AttachmentRef(hash: String(repeating: "a", count: 64), name: "Audio Message.m4a", mimeType: "audio/mp4",
                      byteCount: byteCount, durationMs: 2_000)
    }

    /// An audio part is Messages' audio bubble (play, waveform, length), not a file row.
    @Test func audioPartsShowAsAudioMessages() {
        let shown = HomeMapping.attachment(Self.ref(), picture: nil, progress: nil)
        #expect(shown.kind == "voiceMemo")
        #expect(shown.durationSeconds == 2)
        let song = HomeMapping.attachment(AttachmentRef(hash: "b", name: "song.mp3", mimeType: "audio/mpeg", byteCount: 9), picture: nil, progress: nil)
        #expect(song.kind == "voiceMemo", "any audio the owner takes plays in place")
    }

    /// The bubble's bars are the recording's levels, read once from its bytes:
    /// loud where it speaks, flat where it is silent (never a made-up shape).
    @Test func waveformComesFromTheRecording() async throws {
        let wav = try Self.recording()
        defer { try? FileManager.default.removeItem(at: wav) }
        let media = HomeMedia()
        media.fetch = { _, variant in
            #expect(variant == .original)
            return wav
        }
        let ref = Self.ref()
        media.request(ref)
        await media.settled()
        let asset = try #require(media.asset(ref.hash), "the levels are ready for the bubble")
        let shown = HomeMapping.attachment(ref, picture: asset, progress: nil)
        let levels = try #require(VoiceMemoLevels.load(shown.asset))
        #expect(levels.count == VoiceMemoLevels.bars)
        let half = levels.count / 2
        #expect(levels.prefix(half).max()! > 0.5, "the spoken half is loud")
        #expect(levels.suffix(half - 2).max()! < 0.25, "the silent half is flat")
    }
}
