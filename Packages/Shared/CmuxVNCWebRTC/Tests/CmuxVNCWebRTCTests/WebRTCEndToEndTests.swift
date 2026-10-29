import CmuxVNC
import CmuxVNCDemoServer
import CmuxVNCWebRTC
import Foundation
import Testing

/// Viewer and host in one process through the real signaling Worker
/// (`CMUX_VNC_WEBRTC_LIVE=1`): RFB over a WebRTC data channel to the demo server.
struct WebRTCEndToEndTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_WEBRTC_LIVE"] == "1"), .timeLimit(.minutes(2)))
    func viewerStreamsThroughTheHost() async throws {
        let server = VNCDemoServer(configuration: .init(width: 640, height: 400, password: "hunter2"))
        let port = try await server.start()
        defer { server.stop() }
        let pairing = VNCPairing.generate(name: "test")
        let host = VNCWebRTCHost(pairing: pairing, targetHost: "127.0.0.1", targetPort: port) { print("host: \($0)") }
        let hostTask = Task { await host.run() }
        defer { hostTask.cancel() }
        // The host creates the room; give its socket a moment before the viewer joins.
        try await Task.sleep(for: .seconds(2))

        let started = ContinuousClock.now
        let client = VNCClient(endpoint: VNCEndpoint(host: "webrtc", port: 1),
                               options: VNCSessionOptions(credentials: VNCCredentials(password: "hunter2")),
                               transport: WebRTCRFBTransport(pairing: pairing))
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case let .connected(info)? = await events.next() else {
            Issue.record("did not connect")
            return
        }
        print("webrtc: connected to \(info.name) in \(started.duration(to: .now))")
        var count = 0
        for await frame in client.frames {
            #expect(frame.width == 640)
            count += 1
            if count == 20 { break }
        }
        let stats = await client.stats
        print("webrtc: 20 frames, \(stats.bytesReceived) bytes, latency \(stats.lastUpdateLatencyMs ?? -1) ms")
        #expect(count == 20)
        await client.disconnect()
    }
}
