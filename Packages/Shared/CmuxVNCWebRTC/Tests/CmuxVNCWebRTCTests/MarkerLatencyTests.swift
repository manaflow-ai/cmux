import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// Glass-to-glass latency under consecutive input, against a running stream
/// host showing the marker app (experiments/cmux-vnc-ios/host/marker):
/// `CMUX_VNC_STREAM_LINK`, `CMUX_VNC_MARKER="x,y,w,h"` (video pixels).
/// Sends bursts of keys and pointer moves at fixed rates, reads the counter
/// from every decoded frame, and reports per-input latency and its trend.
struct MarkerLatencyTests {
    final class MarkerReader: NSObject, RTCVideoRenderer, @unchecked Sendable {
        let rect: CGRect
        private let lock = NSLock()
        /// Time each counter value was first seen.
        private var seen: [UInt8: ContinuousClock.Instant] = [:]
        private(set) var last: UInt8?
        init(rect: CGRect) { self.rect = rect }
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame, let value = read(frame) else { return }
            let now = ContinuousClock.now
            lock.withLock {
                if seen[value] == nil { seen[value] = now }
                last = value
            }
        }
        func firstSeen(_ value: UInt8) -> ContinuousClock.Instant? { lock.withLock { seen[value] } }
        var current: UInt8? { lock.withLock { last } }
        func reset() { lock.withLock { seen.removeAll() } }

        /// Luma at the middle of each of the 8 cells.
        private func read(_ frame: RTCVideoFrame) -> UInt8? {
            let cell = rect.width / 8
            func sample(_ luma: (Int, Int) -> UInt8) -> UInt8 {
                var value: UInt8 = 0
                for bit in 0 ..< 8 {
                    let x = Int(rect.minX + cell * (CGFloat(bit) + 0.5)), y = Int(rect.midY)
                    value = value << 1 | (luma(x, y) > 128 ? 1 : 0)
                }
                return value
            }
            if let buffer = frame.buffer as? RTCCVPixelBuffer {
                let pixels = buffer.pixelBuffer
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                return sample { x, y in bytes[y * stride + x] }
            }
            let i420 = frame.buffer.toI420()
            return sample { x, y in i420.dataY[y * Int(i420.strideY) + x] }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_MARKER"] != nil), .timeLimit(.minutes(3)))
    func latencyUnderConsecutiveInput() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairing = try #require(URL(string: env["CMUX_VNC_STREAM_LINK"] ?? "").flatMap(VNCPairing.init(link:)))
        let parts = (env["CMUX_VNC_MARKER"] ?? "").split(separator: ",").compactMap { Double($0) }
        let reader = MarkerReader(rect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(reader) }
        try await viewer.connect()
        defer { viewer.close() }
        for _ in 0 ..< 100 where reader.current == nil { try await Task.sleep(for: .milliseconds(100)) }
        let marker = reader.rect
        func center(_ dx: Double) -> (Double, Double) {
            // Normalized pointer positions inside the marker window (1920x1080 display).
            ((marker.minX + dx) / 1920, marker.midY / 1080)
        }
        // Click the marker once so it has keyboard focus.
        let (cx, cy) = center(marker.width / 2)
        viewer.send(ScreenInput(t: "move", x: cx, y: cy, b: 1))
        viewer.send(ScreenInput(t: "move", x: cx, y: cy, b: 0))
        try await Task.sleep(for: .seconds(1))

        for (kind, rate, count) in [("key", 20.0, 40), ("key", 50.0, 60), ("move", 60.0, 120), ("key", 2.0, 8)] {
            try await Task.sleep(for: .seconds(1)) // settle between bursts
            guard var expected = reader.current else { Issue.record("no marker in the video"); return }
            reader.reset()
            var sent: [(UInt8, ContinuousClock.Instant)] = []
            for i in 0 ..< count {
                expected &+= 1
                let at = ContinuousClock.now
                if kind == "key" {
                    viewer.send(ScreenInput(t: "chord", k: 0x61, m: []))
                } else {
                    let (x, y) = center(20 + Double(i % 2) * 200)
                    viewer.send(ScreenInput(t: "move", x: x, y: y, b: 0))
                }
                sent.append((expected, at))
                try await Task.sleep(for: .seconds(1 / rate)) // the input rate under test
            }
            try await Task.sleep(for: .seconds(2)) // let the last inputs land
            // An input counts as visible when its counter, or any later one, first shows.
            var latencies: [Double] = []
            var missing = 0
            for (value, at) in sent {
                let shows = (0 ..< 256).compactMap { offset -> ContinuousClock.Instant? in
                    let v = value &+ UInt8(offset % 256)
                    return offset < 64 ? reader.firstSeen(v) : nil
                }.filter { $0 >= at }.min()
                if let shows {
                    let d = at.duration(to: shows).components
                    latencies.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
                } else {
                    missing += 1
                }
            }
            func p(_ q: Double) -> Int { let s = latencies.sorted(); return s.isEmpty ? -1 : Int(s[min(s.count - 1, Int(Double(s.count) * q))]) }
            let firstQuarter = latencies.prefix(max(1, latencies.count / 4)), lastQuarter = latencies.suffix(max(1, latencies.count / 4))
            print(String(format: "marker: %@ at %.0f Hz x%d → p50 %d ms, p90 %d ms, max %d ms; first quarter avg %.0f ms, last quarter avg %.0f ms; not seen %d",
                         kind, rate, count, p(0.5), p(0.9), Int(latencies.max() ?? -1),
                         firstQuarter.reduce(0, +) / Double(firstQuarter.count), lastQuarter.reduce(0, +) / Double(lastQuarter.count), missing))
        }
        let stats = await viewer.videoStats()
        print("marker: video \(stats.codec ?? "?") \(stats.decoder ?? "?"), fps \(stats.fps ?? -1), rtt \(stats.rttMs ?? -1) ms")
    }
}
