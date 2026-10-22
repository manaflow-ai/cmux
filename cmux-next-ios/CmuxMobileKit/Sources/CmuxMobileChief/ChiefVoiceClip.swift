import AVFoundation
import CmuxConversationCore
import Foundation

/// Transcribes the recording at a file URL on this device; nil when it
/// cannot (no permission, no on-device model, nothing said). The app passes
/// the on-device speech recognizer (CmuxMobileVoice); tests pass a fake.
public typealias ChiefAudioTranscriber = @Sendable (URL) async -> String?

/// One audio message's bytes: what the Mac stores, its length and waveform,
/// and its transcript.
///
/// The composer records 16 kHz 16-bit WAV (32 KB a second); it goes to the
/// Mac as AAC in an M4A (about 4 KB a second), the type every Home plays.
/// Length and waveform come from the samples, so a message reads the same on
/// any device whatever sent it.
struct ChiefVoiceClip: Sendable {
    let data: Data
    let mimeType: String

    /// Bars a waveform keeps at most (the bubble resamples to its width).
    static let waveformBars = 120

    /// What the clip shows: its length and its levels, 0...1.
    struct Facts: Sendable, Hashable {
        var duration: TimeInterval
        var waveform: [Float]
    }

    /// The clip to upload: AAC when the recording is WAV and encodes, else
    /// the bytes as they are (already compressed, or an encoder failure:
    /// the Mac takes WAV too).
    func forUpload() -> ChiefVoiceClip {
        guard mimeType == "audio/wav", let aac = Self.aac(fromWAV: data) else { return self }
        return ChiefVoiceClip(data: aac, mimeType: "audio/mp4")
    }

    /// The file name the Mac shows and the Chief saves it under.
    func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = mimeType == "audio/wav" ? "wav" : mimeType == "audio/mpeg" ? "mp3" : mimeType == "audio/aac" ? "aac" : "m4a"
        return "Audio Message \(formatter.string(from: date)).\(ext)"
    }

    /// Length and levels read from the samples; nil when they do not decode.
    func facts() -> Facts? {
        guard let samples = withTemporaryFile({ try ConversationWAV.decode(contentsOf: $0) }), !samples.isEmpty else { return nil }
        let rate = Double(ConversationWAV.sampleRate)
        // One level per 50 ms, the composer's meter step (ConversationAudioRecorder.levelInterval).
        let bucket = Int(0.05 * rate)
        let levels = ConversationWAV.levels(samples, bucket: bucket)
        return Facts(duration: Double(samples.count) / rate,
                     waveform: ConversationAudioInfo.resample(levels, count: min(levels.count, Self.waveformBars)))
    }

    /// The clip's transcript from `transcriber`, trimmed; nil when empty.
    func transcript(using transcriber: ChiefAudioTranscriber?) async -> String? {
        guard let transcriber else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-audio-\(UUID().uuidString).\(fileExtension)")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let text = await transcriber(url)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private var fileExtension: String {
        switch mimeType {
        case "audio/wav": "wav"
        case "audio/mpeg": "mp3"
        case "audio/aac": "aac"
        default: "m4a"
        }
    }

    /// Runs `body` on the clip written to a temporary file (AVAudioFile reads files only).
    private func withTemporaryFile<T>(_ body: (URL) throws -> T) -> T? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-audio-\(UUID().uuidString).\(fileExtension)")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? body(url)
    }

    /// Mono AAC at the recording's 16 kHz, 32 kbit/s: speech stays clear.
    static func aac(fromWAV wav: Data) -> Data? {
        let directory = FileManager.default.temporaryDirectory
        let input = directory.appendingPathComponent("chief-audio-\(UUID().uuidString).wav")
        let output = directory.appendingPathComponent("chief-audio-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        do {
            try wav.write(to: input)
            let source = try AVAudioFile(forReading: input)
            let format = source.processingFormat
            guard source.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length)) else { return nil }
            try source.read(into: buffer)
            do {
                // Scoped: the file is finished (its moov atom written) when it is released.
                let target = try AVAudioFile(forWriting: output, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: 32_000,
                ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try target.write(from: buffer)
                target.close()
            }
            let encoded = try Data(contentsOf: output)
            return encoded.isEmpty ? nil : encoded
        } catch {
            return nil
        }
    }
}
