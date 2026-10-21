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

    /// A room connection dropping (either side's) must not end a running
    /// stream: video keeps arriving and the viewer reports no end.
    /// A second socket for a role replaces the first, as a reconnect does.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_WEBRTC_LIVE"] == "1"), .timeLimit(.minutes(2)))
    func streamSurvivesRoomConnectionDrops() async throws {
        let server = VNCDemoServer(configuration: .init(width: 1280, height: 800, password: "hunter2"))
        let port = try await server.start()
        defer { server.stop() }
        let pairing = VNCPairing.generate(name: "stream-drop-test", kind: "stream")
        let host = ScreenStreamHost(pairing: pairing, target: VNCEndpoint(host: "127.0.0.1", port: port),
                                    credentials: VNCCredentials(password: "hunter2")) { print("host: \($0)") }
        let hostTask = Task { await host.run() }
        defer { hostTask.cancel() }
        try await Task.sleep(for: .seconds(2)) // the host creates the room

        let counter = FrameCounter()
        let ended = DisplayBox()
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(counter) }
        viewer.onState = { message in
            print("viewer state: \(message ?? "-")")
            ended.set(ScreenHostMessage(t: "ended"))
        }
        try await viewer.connect()
        defer { viewer.close() }
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }

        for role in ["host", "viewer"] {
            let intruder = SignalSocket(pairing: pairing, role: role)
            let reader = Task { for try await _ in intruder.messages() {} }
            try await Task.sleep(for: .seconds(1)) // the room replaces the \(role)'s socket
            intruder.close()
            reader.cancel()
            let before = counter.snapshot.0
            try await Task.sleep(for: .seconds(4)) // frames keep arriving (the loopback source sends 5-12 fps)
            let after = counter.snapshot.0
            print("drop \(role): frames \(before) → \(after)")
            #expect(after - before > 8, "video stopped after the \(role)'s room connection dropped")
            #expect(ended.value == nil, "the viewer ended after the \(role)'s room connection dropped")
        }
    }

    /// The viewer's quality choice reaches the Mac's encoder: Fixed Low
    /// sends 720p, and Auto goes back to the display's full size.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_WEBRTC_LIVE"] == "1"), .timeLimit(.minutes(2)))
    func qualityChoiceChangesTheVideo() async throws {
        let server = VNCDemoServer(configuration: .init(width: 1920, height: 1080, password: "hunter2"))
        let port = try await server.start()
        defer { server.stop() }
        let pairing = VNCPairing.generate(name: "stream-quality-test", kind: "stream")
        let host = ScreenStreamHost(pairing: pairing, target: VNCEndpoint(host: "127.0.0.1", port: port),
                                    credentials: VNCCredentials(password: "hunter2")) { print("host: \($0)") }
        let hostTask = Task { await host.run() }
        defer { hostTask.cancel() }
        try await Task.sleep(for: .seconds(2)) // the host creates the room

        let counter = FrameCounter()
        let viewer = ScreenStreamViewer(pairing: pairing)
        viewer.onVideo = { $0.track.add(counter) }
        try await viewer.connect()
        defer { viewer.close() }
        func height(after seconds: Int) async throws -> Int {
            try await Task.sleep(for: .seconds(seconds)) // the encoder picks up new parameters on the next frames
            return Int(counter.snapshot.1.height)
        }
        #expect(try await height(after: 3) == 1080)
        viewer.setQuality(.low)
        let low = try await height(after: 3)
        print("quality low: \(low)p")
        #expect(low == 720)
        viewer.setQuality(.auto)
        #expect(try await height(after: 3) == 1080)
    }
}

final class DisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: ScreenHostMessage?
    func set(_ message: ScreenHostMessage) { lock.withLock { self.message = message } }
    var value: ScreenHostMessage? { lock.withLock { message } }
}
