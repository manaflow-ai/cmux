import CmuxVNCWebRTC
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WebRTC

/// Glass-to-glass latency of this WebRTC stream measured exactly as `cmux-rd bench --input click`
/// measures the `cmux.rd/1` host, so the two engines compare on the same host Mac, viewer and
/// marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`, 20 cells, counter LSB first,
/// guard 1,0,1,0): one click on the marker, the time until a decoded frame shows the next
/// counter (1 s = lost), then a random 40 to 160 ms gap. Clicks land on the marker's click pad,
/// which sits above every other window, so no test input reaches another app on the host.
///
/// `CMUX_VNC_STREAM_LINK` the host's pairing link; `CMUX_RD_MARKER_CELL_FRACTION` one cell's
/// width as a fraction of the frame width (32 / the width the rd host streams that display at);
/// `CMUX_RD_MARKER_ORIGIN_Y` the marker's top as a fraction of the frame height (the marker
/// prints its `marker-origin` in rd stream pixels; divide by that stream's height); optional `CMUX_RD_MARKER_SAMPLES` (default 300) and `CMUX_RD_MARKER_SNAPSHOT` (a PNG of the
/// newest decoded frame). Prints one JSON line, `rdmarker: {...}`.
struct RdMarkerClickLatencyTests {
    final class Reader: NSObject, RTCVideoRenderer, @unchecked Sendable {
        let fraction: Double
        let originY: Double
        private let lock = NSLock()
        private var current: UInt16?
        private var seenAt: ContinuousClock.Instant?
        private var waiter: (value: UInt16, resume: CheckedContinuation<ContinuousClock.Instant?, Never>)?
        private var size: CGSize = .zero
        private var newest: CVPixelBuffer?
        init(fraction: Double, originY: Double) { self.fraction = fraction; self.originY = originY }

        func setSize(_ size: CGSize) {}

        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame, let (value, pixels) = read(frame) else { return }
            let now = ContinuousClock.now
            let resume = lock.withLock { () -> CheckedContinuation<ContinuousClock.Instant?, Never>? in
                size = CGSize(width: Int(frame.width), height: Int(frame.height))
                if let pixels { newest = pixels }
                guard value != current else { return nil }
                current = value
                seenAt = now
                guard let waiter, waiter.value == value else { return nil }
                self.waiter = nil
                return waiter.resume
            }
            resume?.resume(returning: now)
        }

        var value: UInt16? { lock.withLock { current } }
        var frameSize: CGSize { lock.withLock { size } }
        var pixels: CVPixelBuffer? { lock.withLock { newest } }

        /// When the marker first shows `value`, or nil when `cancelWait` ends the wait.
        func firstShows(_ value: UInt16) async -> ContinuousClock.Instant? {
            await withCheckedContinuation { (continuation: CheckedContinuation<ContinuousClock.Instant?, Never>) in
                let done = lock.withLock { () -> ContinuousClock.Instant?? in
                    if current == value { return .some(seenAt) }
                    waiter = (value, continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        }

        /// Ends a wait that did not finish in time.
        func cancelWait() {
            let resume = lock.withLock { () -> CheckedContinuation<ContinuousClock.Instant?, Never>? in
                defer { waiter = nil }
                return waiter?.resume
            }
            resume?.resume(returning: nil)
        }

        private func read(_ frame: RTCVideoFrame) -> (UInt16, CVPixelBuffer?)? {
            let width = Double(frame.width)
            let cell = fraction * width
            let top = originY * Double(frame.height)
            func decode(_ luma: (Int, Int) -> UInt8) -> UInt16? {
                var bits = [Bool](repeating: false, count: 20)
                for i in 0 ..< 20 {
                    bits[i] = luma(Int((Double(i) + 0.5) * cell), Int(top + cell / 2)) > 125
                }
                guard Array(bits[16...]) == [true, false, true, false] else { return nil }
                return bits[..<16].enumerated().reduce(0) { $0 | (($1.element ? 1 : 0) << UInt16($1.offset)) }
            }
            if let buffer = frame.buffer as? RTCCVPixelBuffer {
                let pixels = buffer.pixelBuffer
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                return decode { x, y in bytes[y * stride + x] }.map { ($0, pixels) }
            }
            let i420 = frame.buffer.toI420()
            return decode { x, y in i420.dataY[y * Int(i420.strideY) + x] }.map { ($0, nil) }
        }
    }

    private func percentiles(_ values: [Double]) -> [String: Double] {
        let s = values.sorted()
        guard !s.isEmpty else { return [:] }
        func q(_ p: Double) -> Double { s[Int((p * Double(s.count - 1)).rounded())] }
        return ["n": Double(s.count), "min": s[0], "p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": s[s.count - 1]]
    }

    private func writePNG(_ pixels: CVPixelBuffer, to path: String) {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_RD_MARKER_CELL_FRACTION"] != nil), .timeLimit(.minutes(5)))
    func clickLatencyOnTheRdMarker() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairing = try #require(URL(string: env["CMUX_VNC_STREAM_LINK"] ?? "").flatMap(VNCPairing.init(link:)))
        let fraction = try #require(Double(env["CMUX_RD_MARKER_CELL_FRACTION"] ?? ""))
        let samples = Int(env["CMUX_RD_MARKER_SAMPLES"] ?? "") ?? 300
        let originY = Double(env["CMUX_RD_MARKER_ORIGIN_Y"] ?? "") ?? 0
        let reader = Reader(fraction: fraction, originY: originY)
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(reader) }
        let connectStart = ContinuousClock.now
        try await viewer.connect()
        defer { viewer.close() }
        // The first decoded marker (bounded: 15 s, as the rd bench).
        for _ in 0 ..< 150 where reader.value == nil { try await Task.sleep(for: .milliseconds(100)) }
        let firstFrameMs = connectStart.duration(to: .now) / .milliseconds(1)
        try #require(reader.value != nil, "no marker in the video within 15 s")
        let size = reader.frameSize
        // The marker's click pad (cells 20 to 23, never read), so the cursor the host draws
        // never covers a read cell; normalized to the display.
        let at = (x: 22 * fraction, y: originY + 0.5 * fraction * size.width / size.height)

        let before = await viewer.videoStats()
        let started = ContinuousClock.now
        var latencies: [Double] = []
        var lost = 0
        while latencies.count + lost < samples {
            guard let current = reader.value else { break }
            let expected = current &+ 1
            let sent = ContinuousClock.now
            viewer.send(ScreenInput(t: "move", x: at.x, y: at.y, b: 1))
            viewer.send(ScreenInput(t: "move", x: at.x, y: at.y, b: 0))
            let timeout = Task {
                // The rd bench's loss deadline; a cancelled timer must not end the next wait.
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                reader.cancelWait()
            }
            let shown = await reader.firstShows(expected)
            timeout.cancel()
            if let shown {
                latencies.append(sent.duration(to: shown) / .milliseconds(1))
            } else {
                lost += 1
            }
            try await Task.sleep(for: .milliseconds(Int.random(in: 40 ... 160))) // the rd bench's gap
        }
        let seconds = started.duration(to: .now) / .seconds(1)
        let after = await viewer.videoStats()
        if let path = env["CMUX_RD_MARKER_SNAPSHOT"], let pixels = reader.pixels { writePNG(pixels, to: path) }
        let report: [String: Any] = [
            "engine": "webrtc (CmuxVNCWebRTC ScreenStreamHost)",
            "g2g_ms": percentiles(latencies),
            "lost": lost,
            "connect_to_first_marker_ms": firstFrameMs,
            "frame": ["width": size.width, "height": size.height],
            "frames_per_s": (after.framesDecoded - before.framesDecoded) / seconds,
            "mbit_per_s": (after.bytesReceived - before.bytesReceived) * 8 / seconds / 1e6,
            "decode_ms_mean": after.framesDecoded > 0 ? after.totalDecodeTime / after.framesDecoded * 1000 : -1,
            "rtt_ms": after.rttMs ?? -1,
            "jitter_buffer_ms": after.jitterBufferMs ?? -1,
            "codec": after.codec ?? "?",
            "decoder": after.decoder ?? "?",
            "packets_lost": after.packetsLost - before.packetsLost,
            "frames_dropped": after.framesDropped - before.framesDropped,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("rdmarker: \(String(decoding: json, as: UTF8.self))")
        #expect(latencies.count > samples / 2, "most clicks never showed: \(lost) lost of \(samples)")
    }
}
