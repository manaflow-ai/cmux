import CmuxVNC
import CmuxVNCWebRTC
import Foundation
import Testing

/// `CMUX_VNC_LINK=<cmux-vnc://pair…>` (+ CMUX_VNC_USER/PASSWORD): connects as a
/// viewer to a running cmux-vnc-host and waits for one frame.
struct LinkViewerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_LINK"] != nil), .timeLimit(.minutes(1)))
    func viewerReachesARunningHost() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairing = try #require(URL(string: env["CMUX_VNC_LINK"]!).flatMap(VNCPairing.init(link:)))
        let started = ContinuousClock.now
        let client = VNCClient(endpoint: VNCEndpoint(host: "webrtc", port: 1),
                               options: VNCSessionOptions(credentials: VNCCredentials(username: env["CMUX_VNC_USER"], password: env["CMUX_VNC_PASSWORD"])),
                               transport: WebRTCRFBTransport(pairing: pairing))
        await client.connect()
        var events = client.events.makeAsyncIterator()
        let first = await events.next()
        print("link-viewer: \(String(describing: first)) after \(started.duration(to: .now))")
        guard case .connected = first else { Issue.record("no connect"); return }
        var frames = client.frames.makeAsyncIterator()
        _ = await frames.next()
        print("link-viewer: first frame after \(started.duration(to: .now))")
        await client.disconnect()
    }
}
