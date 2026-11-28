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

/// `CMUX_VNC_LIVE_PROBE=1`: input-to-update latency against the live server.
/// Moves the pointer, then times the next framebuffer update (the server
/// redraws its cursor), 40 times, and prints p50/p90 plus decode time.
struct LiveLatencyProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_LIVE_PROBE"] == "1"))
    func inputToUpdate() async throws {
        let env = ProcessInfo.processInfo.environment
        let parsed = try #require(VNCEndpoint.parse(env["CMUX_VNC_LIVE_HOST"] ?? ""))
        let client = VNCClient(endpoint: parsed.endpoint, options: VNCSessionOptions(
            credentials: VNCCredentials(username: env["CMUX_VNC_LIVE_USER"], password: env["CMUX_VNC_LIVE_PASSWORD"]),
            localCursor: env["CMUX_VNC_LIVE_LOCAL_CURSOR"] == "1"))
        let connectStart = ContinuousClock.now
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case let .connected(info)? = await events.next() else { Issue.record("no connect"); return }
        var frames = client.frames.makeAsyncIterator()
        _ = await frames.next()
        print("probe: connected + first full frame \(info.width)x\(info.height) in \(connectStart.duration(to: .now))")
        var samples: [Double] = []
        var decode: [Double] = []
        var areas: [Double] = []
        for step in 0 ..< 40 {
            let x = 200 + (step % 2) * 600, y = 300 + (step % 3) * 150
            let spotlight = env["CMUX_VNC_PROBE_ACTION"] == "spotlight"
            if spotlight {
                // Let the previous change finish arriving before the next action.
                try? await Task.sleep(for: .milliseconds(1500))
            }
            let before = await client.stats.frames
            let sent = ContinuousClock.now
            if spotlight {
                if step % 2 == 0 { await client.chord([.command], .space) } else { await client.key(.escape, down: true); await client.key(.escape, down: false) }
            } else {
                await client.movePointer(x: x, y: y)
            }
            var fresh = false
            while let frame = await frames.next() {
                if frame.sequence > before { fresh = true; break }
            }
            guard fresh else { break }
            let elapsed = sent.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            if let ms = await client.stats.lastDecodeMs { decode.append(ms) }
            areas.append(Double(await client.stats.lastUpdatePixels))
        }
        func pct(_ values: [Double], _ p: Double) -> Int { Int(values.sorted()[min(values.count - 1, Int(Double(values.count) * p))]) }
        let stats = await client.stats
        print("probe: input→update p50 \(pct(samples, 0.5)) ms, p90 \(pct(samples, 0.9)) ms; receive+decode p50 \(pct(decode, 0.5)) ms; update area p50 \(pct(areas, 0.5)) px; bytes \(stats.bytesReceived); by encoding \(stats.rectanglesByEncoding)")
        await client.disconnect()
    }
}

