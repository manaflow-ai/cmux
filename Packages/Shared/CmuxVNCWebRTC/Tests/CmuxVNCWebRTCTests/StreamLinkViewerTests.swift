import CmuxVNCWebRTC
import Foundation
import Testing
import WebRTC

/// `CMUX_VNC_STREAM_LINK=<cmux-vnc://pair…kind=stream>`: joins a running
/// screen-stream host, decodes `CMUX_VNC_STREAM_SECONDS` (default 8) of
/// video, and prints frame and WebRTC numbers.
struct StreamLinkViewerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_STREAM_LINK"] != nil), .timeLimit(.minutes(2)))
    func viewerDecodesARunningHost() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairing = try #require(URL(string: env["CMUX_VNC_STREAM_LINK"]!).flatMap(VNCPairing.init(link:)))
        let counter = ScreenStreamTests.FrameCounter()
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(counter) }
        viewer.onPath = { print("link-stream: path \($0)") }
        let started = ContinuousClock.now
        try await viewer.connect()
        defer { viewer.close() }
        for _ in 0 ..< 200 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        print("link-stream: first frame after \(started.duration(to: .now))")
        let seconds = Double(env["CMUX_VNC_STREAM_SECONDS"] ?? "8") ?? 8
        let before = counter.snapshot.0
        try await Task.sleep(for: .seconds(seconds))
        let (frames, size) = counter.snapshot
        let stats = await viewer.videoStats()
        print(String(format: "link-stream: %.1f fps rendered, %dx%d, codec %@ %@, %.0f KB, rtt %@ ms, jitter buffer %@ ms",
                     Double(frames - before) / seconds, Int(size.width), Int(size.height), stats.codec ?? "?", stats.decoder ?? "?",
                     stats.bytesReceived / 1024, stats.rttMs.map { String(format: "%.0f", $0) } ?? "-",
                     stats.jitterBufferMs.map { String(format: "%.0f", $0) } ?? "-"))
        #expect(frames > 0)
    }
}
