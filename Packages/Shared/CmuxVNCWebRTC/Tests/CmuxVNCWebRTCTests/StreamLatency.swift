#if os(macOS)
import CoreVideo
import Foundation
import WebRTC

/// A 16-bit frame index drawn into the top-left of a synthetic screen's luma, and
/// read back from a decoded frame: two rows of 16 cells, the index and its
/// complement (a frame whose rows disagree, a smeared or half-updated one, reads as
/// nil). Cells are 32 source pixels, black or white, so they survive the encoder
/// and Auto's downscale (3456 → 2154 wide leaves 20-pixel cells).
enum FrameStamp {
    static let cell = 32
    static let bits = 16

    static func draw(_ value: UInt16, into luma: UnsafeMutablePointer<UInt8>, stride: Int) {
        for row in 0 ..< 2 {
            let word = row == 0 ? value : ~value
            for bit in 0 ..< bits {
                let shade: UInt8 = (word >> UInt16(bits - 1 - bit)) & 1 == 1 ? 235 : 16
                for y in row * cell ..< (row + 1) * cell {
                    memset(luma + y * stride + bit * cell, Int32(shade), cell)
                }
            }
        }
    }

    /// The index in `frame`, whose picture is `scale` × the source's size; nil when
    /// the two rows disagree.
    static func read(_ frame: RTCVideoFrame, scale: Double) -> UInt16? {
        func decode(_ luma: (Int, Int) -> UInt8) -> UInt16? {
            var words: [UInt16] = [0, 0]
            for row in 0 ..< 2 {
                let y = Int((Double(row * cell) + Double(cell) / 2) * scale)
                for bit in 0 ..< bits {
                    let x = Int((Double(bit * cell) + Double(cell) / 2) * scale)
                    words[row] = words[row] << 1 | (luma(x, y) > 128 ? 1 : 0)
                }
            }
            return words[0] == ~words[1] ? words[0] : nil
        }
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let pixels = buffer.pixelBuffer
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return decode { x, y in bytes[y * stride + x] }
        }
        let i420 = frame.buffer.toI420()
        return decode { x, y in i420.dataY[y * Int(i420.strideY) + x] }
    }
}

/// Reads each decoded frame's stamp and keeps, per distinct frame, the time from
/// the source handing it to the host to libwebrtc handing it, decoded, to the
/// viewer's renderers (capture → encode → send → receive → decode), on one clock.
final class StreamLatencyReader: NSObject, RTCVideoRenderer, @unchecked Sendable {
    // @unchecked: state is behind `lock`; renderFrame runs on libwebrtc's one render thread.
    private let sourceWidth: Double
    private let deliveredAt: @Sendable (UInt16) -> UInt64?
    private let lock = NSLock()
    private var seen = Set<UInt16>()
    private var samples: [(at: UInt64, ms: Double)] = []
    private var unreadable = 0

    init(sourceWidth: Int, deliveredAt: @escaping @Sendable (UInt16) -> UInt64?) {
        self.sourceWidth = Double(sourceWidth)
        self.deliveredAt = deliveredAt
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let frame else { return }
        guard let stamp = FrameStamp.read(frame, scale: Double(frame.width) / sourceWidth) else {
            lock.withLock { unreadable += 1 }
            return
        }
        guard let sent = deliveredAt(stamp), sent <= now else { return }
        lock.withLock {
            guard seen.insert(stamp).inserted else { return }
            samples.append((now, Double(now - sent) / 1e6))
            if seen.count > 30000 { seen.removeAll(keepingCapacity: true) }
        }
    }

    /// Latencies of the frames decoded since `since` (uptime ns).
    func window(since: UInt64) -> StreamLatencySummary {
        lock.withLock { StreamLatencySummary(samples.filter { $0.at >= since }.map(\.ms), unreadable: unreadable) }
    }
}

struct StreamLatencySummary: CustomStringConvertible {
    let count: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double
    let unreadable: Int

    init(_ values: [Double], unreadable: Int) {
        let sorted = values.sorted()
        func rank(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            // Nearest rank.
            let rank = Int((q * Double(sorted.count)).rounded(.up))
            return sorted[Swift.min(sorted.count, Swift.max(rank, 1)) - 1]
        }
        count = sorted.count
        p50 = rank(0.50)
        p95 = rank(0.95)
        p99 = rank(0.99)
        max = sorted.last ?? .nan
        self.unreadable = unreadable
    }

    var description: String {
        String(format: "frames=%d p50_ms=%.1f p95_ms=%.1f p99_ms=%.1f max_ms=%.1f unreadable=%d", count, p50, p95, p99, max, unreadable)
    }
}
#endif
