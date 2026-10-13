import CmuxVNC
import CmuxVNCDemoServer
@testable import CmuxVNCWebRTC
import Foundation
import Testing
import WebRTC

/// The screen as WebRTC video, end to end through the deployed Worker
/// (`CMUX_VNC_WEBRTC_LIVE=1`): host reads the demo server, viewer decodes.
struct ScreenStreamTests {
    final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var frames = 0
        private(set) var size = CGSize.zero
        func setSize(_ size: CGSize) { lock.withLock { self.size = size } }
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            lock.withLock {
                frames += 1
                size = CGSize(width: Int(frame.width), height: Int(frame.height))
            }
        }
        var snapshot: (Int, CGSize) { lock.withLock { (frames, size) } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_WEBRTC_LIVE"] == "1"), .timeLimit(.minutes(2)))
    func viewerDecodesTheScreenTrack() async throws {
        let server = VNCDemoServer(configuration: .init(width: 1280, height: 800, password: "hunter2"))
        let port = try await server.start()
        defer { server.stop() }
        let pairing = VNCPairing.generate(name: "stream-test", kind: "stream")
        let host = ScreenStreamHost(pairing: pairing, target: VNCEndpoint(host: "127.0.0.1", port: port),
                                    credentials: VNCCredentials(password: "hunter2")) { print("host: \($0)") }
        let hostTask = Task { await host.run() }
        defer { hostTask.cancel() }
        try await Task.sleep(for: .seconds(2)) // the host creates the room

        print("stream: receive codecs \(VNCPeerLink.receiveCodecNames())")
        let counter = FrameCounter()
        let displays = DisplayBox()
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { box in
            print("stream: got track \(box.track.trackId) enabled \(box.track.isEnabled) state \(box.track.readyState.rawValue)")
            box.track.add(counter)
        }
        viewer.onDisplays = { displays.set($0) }
        let started = ContinuousClock.now
        try await viewer.connect()
        defer { viewer.close() }
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        print("stream: first frame after \(started.duration(to: .now))")
        try await Task.sleep(for: .seconds(5)) // the demo desktop animates at 30 fps
        let (frames, size) = counter.snapshot
        let stats = await viewer.videoStats()
        print("stream: \(frames) frames decoded \(Int(size.width))x\(Int(size.height)), fps \(stats.fps ?? -1), codec \(stats.codec ?? "?") decoder \(stats.decoder ?? "?"), \(Int(stats.bytesReceived / 1024)) KB received, rtt \(stats.rttMs ?? -1) ms, jitter buffer \(stats.jitterBufferMs ?? -1) ms, displays \(String(describing: displays.value?.displays))")
        #expect(frames > 30)
        #expect(Int(size.width) == 1280)
        // Input reaches the server through the channel.
        viewer.send(ScreenInput(t: "text", s: "hi"))
        try await Task.sleep(for: .seconds(1))
        #expect(await server.typedText() == "hi")
    }
}

final class DisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: ScreenHostMessage?
    func set(_ message: ScreenHostMessage) { lock.withLock { self.message = message } }
    var value: ScreenHostMessage? { lock.withLock { message } }
}
