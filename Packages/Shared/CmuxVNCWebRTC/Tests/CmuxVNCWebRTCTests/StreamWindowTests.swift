import CmuxVNCWebRTC
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WebRTC

/// A passive viewer window for the screen stream eval (scripts/measure/screen-stream-eval), the
/// WebRTC twin of `cmux-rd bench --input none`: connects to a running stream host, sends no input,
/// and every second records the bytes, frames and mean decode time the viewer saw, stamped with
/// the Unix ms clock the eval's scene stamps its phases with, so the eval cuts one run into idle,
/// typing and scrolling.
///
/// `CMUX_VNC_STREAM_LINK` the host's pairing link; `CMUX_EVAL_WINDOW_S` how long to receive after
/// the first frame (the test runs only when it is set); optional `CMUX_EVAL_SNAPSHOT` (a PNG of the
/// last decoded frame). Prints `streamwindow: first frame` once video shows, then one JSON line,
/// `streamwindow: {...}`.
struct StreamWindowTests {
    final class Newest: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var pixels: CVPixelBuffer?
        private var frames = 0
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer
            lock.withLock {
                frames += 1
                if let buffer { pixels = buffer }
            }
        }
        var rendered: Int { lock.withLock { frames } }
        var newest: CVPixelBuffer? { lock.withLock { pixels } }
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

    private func unixMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_EVAL_WINDOW_S"] != nil), .timeLimit(.minutes(5)))
    func passiveWindow() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairing = try #require(URL(string: env["CMUX_VNC_STREAM_LINK"] ?? "").flatMap(VNCPairing.init(link:)))
        let seconds = try #require(Int(env["CMUX_EVAL_WINDOW_S"] ?? ""))
        let reader = Newest()
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(reader) }
        try await viewer.connect()
        defer { viewer.close() }
        // The first frame (bounded: 15 s, as the rd bench).
        for _ in 0 ..< 150 where reader.rendered == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try #require(reader.rendered > 0, "no video within 15 s")
        print("streamwindow: first frame")
        var series: [[String: Any]] = []
        var last = await viewer.videoStats()
        let first = last
        let clock = ContinuousClock()
        var next = clock.now
        for _ in 0 ..< seconds {
            next += .seconds(1)
            try await Task.sleep(until: next, clock: clock)
            let now = await viewer.videoStats()
            let decoded = now.framesDecoded - last.framesDecoded
            series.append([
                "unix_ms": unixMs(),
                "bytes": now.bytesReceived - last.bytesReceived,
                "frames": decoded,
                "decode_ms_mean": decoded > 0 ? (now.totalDecodeTime - last.totalDecodeTime) / decoded * 1000 : -1,
                "rtt_ms": now.rttMs ?? -1,
                "jitter_buffer_ms": now.jitterBufferMs ?? -1,
            ])
            last = now
        }
        if let path = env["CMUX_EVAL_SNAPSHOT"], let pixels = reader.newest { writePNG(pixels, to: path) }
        let report: [String: Any] = [
            "engine": "webrtc (CmuxVNCWebRTC ScreenStreamHost)",
            "seconds": seconds,
            "series": series,
            "codec": last.codec ?? "?",
            "decoder": last.decoder ?? "?",
            "packets_lost": last.packetsLost - first.packetsLost,
            "frames_dropped": last.framesDropped - first.framesDropped,
            "freezes": last.freezeCount - first.freezeCount,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("streamwindow: \(String(decoding: json, as: UTF8.self))")
    }
}
