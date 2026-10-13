import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxVNC

/// Against a real server, only when `CMUX_VNC_LIVE_HOST` is set
/// (`host[:port]`, plus `CMUX_VNC_LIVE_USER` / `CMUX_VNC_LIVE_PASSWORD`;
/// `CMUX_VNC_LIVE_PNG` saves the first frame). Used to check macOS Screen
/// Sharing (Apple DH) and other servers by hand; skipped in CI.
struct LiveServerTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["CMUX_VNC_LIVE_HOST"] != nil))
    func connectsAndReceivesAFrame() async throws {
        let env = Self.environment
        let parsed = try #require(VNCEndpoint.parse(env["CMUX_VNC_LIVE_HOST"] ?? ""))
        let credentials = VNCCredentials(username: env["CMUX_VNC_LIVE_USER"], password: env["CMUX_VNC_LIVE_PASSWORD"])
        let client = VNCClient(endpoint: parsed.endpoint, options: VNCSessionOptions(credentials: credentials))
        await client.connect()
        var events = client.events.makeAsyncIterator()
        let first = await events.next()
        guard case let .connected(info)? = first else {
            Issue.record("did not connect: \(String(describing: first))")
            return
        }
        print("live: \(info.name) \(info.width)x\(info.height) RFB 3.\(info.protocolMinor) security \(info.securityType)")
        var frames = client.frames.makeAsyncIterator()
        let remaining = events
        Task {
            var iterator = remaining
            while let event = await iterator.next() { if case let .screens(screens) = event { print("live: screens \(screens)") } }
        }
        var frame = try #require(await frames.next())
        print("live: first-frame screens \(VNCScreenLayout().screens(in: frame))")
        // Later updates paint the other displays.
        for _ in 0 ..< (Int(env["CMUX_VNC_LIVE_FRAMES"] ?? "0") ?? 0) {
            guard let next = await frames.next() else { break }
            frame = next
        }
        #expect(frame.width == info.width && frame.height == info.height)
        print("live: detected screens \(VNCScreenLayout().screens(in: frame))")
        let stats = await client.stats
        print("live: \(stats.rectangles) rectangles \(stats.rectanglesByEncoding) \(stats.bytesReceived) bytes, latency \(stats.lastUpdateLatencyMs ?? -1) ms")
        if let path = env["CMUX_VNC_LIVE_PNG"], let image = frame.makeImage(),
           let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        await client.disconnect()
    }
}
