import AVFoundation
import Foundation

/// The waveform of an audio message bubble: one level (0...1) per bar, read
/// once from the recording's samples.
///
/// The levels travel as the attachment's `asset` string (`levels:` and one
/// hex byte per bar), so the row drawing stays a pure function of the
/// attachment value: no file read while drawing, and a row redraws exactly
/// when its levels arrive. Until then the bubble draws flat bars.
struct VoiceMemoLevels {
    /// Bars in the 196 pt bubble (RowDrawing: 3.6 pt apart from x 38).
    static let bars = 30
    private static let prefix = "levels:"

    /// The asset string for `levels` (each clamped to 0...1).
    static func asset(_ levels: [Float]) -> String {
        prefix + levels.map { String(format: "%02x", UInt8((max(0, min(1, $0)) * 255).rounded())) }.joined()
    }

    /// The levels an asset string holds; nil for any other asset.
    static func load(_ asset: String?) -> [Float]? {
        guard let asset, asset.hasPrefix(prefix) else { return nil }
        let hex = Array(asset.dropFirst(prefix.count).utf8)
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var levels: [Float] = []
        levels.reserveCapacity(hex.count / 2)
        var index = 0
        while index < hex.count {
            guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            levels.append(Float(byte) / 255)
            index += 2
        }
        return levels
    }

    /// `bars` levels of the audio file at `url`: RMS per slice on Messages'
    /// meter scale (-50 dB is silent), then scaled so the loudest bar is
    /// full height. Nil when the file does not decode.
    nonisolated static func measure(_ url: URL, bars: Int = bars) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0, bars > 0 else { return nil }
        var levels = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            let start = bar * count / bars, end = max(start + 1, (bar + 1) * count / bars)
            var sum: Float = 0
            for i in start..<min(end, count) { sum += channel[i] * channel[i] }
            let rms = (sum / Float(end - start)).squareRoot()
            let decibels = rms > 0 ? 20 * log10(rms) : -100
            levels[bar] = max(0, min(1, (decibels + 50) / 50))
        }
        let loudest = levels.max() ?? 0
        return loudest > 0 ? levels.map { $0 / loudest } : levels
    }
}

extension VoiceMemoLevels {
    /// The bars' ink at rest; played bars are full ink.
    static let restAlpha: CGFloat = 0.5

    /// The bubble's bars (RowDrawing's measurements: 2 pt wide, 3.6 pt
    /// apart from x 38, up to 18 pt tall, centred). Nil levels: flat bars.
    static func barRects(_ levels: [Float]?, body: CGRect) -> [CGRect] {
        (0..<bars).map { i in
            let level = levels.flatMap { $0.indices.contains(i) ? CGFloat($0[i]) : nil } ?? 0
            let h = max(2, (0.12 + 0.88 * level) * 18)
            return CGRect(x: body.minX + 38 + CGFloat(i) * 3.6, y: body.midY - h / 2, width: 2, height: h)
        }
    }

    /// The play or pause disc (22 pt at x 8, centred).
    static func discRect(body: CGRect) -> CGRect {
        CGRect(x: body.minX + 8, y: body.midY - 11, width: 22, height: 22)
    }
}
