import Foundation
import Testing
@testable import CmuxVNCWebRTC

/// Data channel throughput through the deployed Worker's ICE servers
/// (`CMUX_VNC_WEBRTC_LIVE=1`): two peers in one process, once forced through
/// the TURN relay and once direct, 20 MB each way-one.
struct ThroughputTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_WEBRTC_LIVE"] == "1"), arguments: [true, false])
    func dataChannelThroughput(relay: Bool) async throws {
        let pairing = VNCPairing.generate(name: "throughput")
        // A host socket creates the room so /ice answers.
        let room = SignalSocket(pairing: pairing, role: "host")
        var roomMessages = room.messages().makeAsyncIterator()
        _ = try await roomMessages.next()
        defer { room.close() }
        var ice = try await SignalSocket.iceServers(pairing)
        // CMUX_VNC_TURN_ONLY=udp|tcp|tls keeps only those relay URLs.
        if let only = ProcessInfo.processInfo.environment["CMUX_VNC_TURN_ONLY"] {
            ice = ice.map { server in
                var copy = server
                copy.urls = server.urls.filter { url in
                    switch only {
                    case "udp": url.hasPrefix("turn:") && url.contains("transport=udp")
                    case "tcp": url.hasPrefix("turn:") && url.contains("transport=tcp")
                    default: url.hasPrefix("turns:")
                    }
                }
                return copy
            }.filter { !$0.urls.isEmpty }
        }

        let viewer = try VNCPeerLink(iceServers: ice, relayOnly: relay)
        let host = try VNCPeerLink(iceServers: ice, relayOnly: relay)
        let total = 20 << 20
        let received = ByteCounter()
        let opened = OpenSignal()
        let done = OpenSignal()
        let viewerEvents = Task {
            for await event in viewer.events {
                switch event {
                case let .candidate(message): await host.add(candidate: message)
                case .open: opened.fire(nil)
                case let .message(data): if received.add(data.count) >= total { done.fire(nil) }
                case let .path(local, remote): print("throughput: relay=\(relay) path \(local) ↔ \(remote)")
                case .closed, .video: break
                }
            }
        }
        let hostEvents = Task {
            for await event in host.events {
                if case let .candidate(message) = event { await viewer.add(candidate: message) }
            }
        }
        defer {
            viewerEvents.cancel()
            hostEvents.cancel()
            viewer.close()
            host.close()
        }
        let offer = try await viewer.offer()
        let answer = try await host.answer(offer: offer)
        try await viewer.accept(answer: answer)
        try await opened.wait(timeout: 20)
        // Give the host side's channel a beat to open too.
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let chunk = Data(count: 256 * 1024)
        Task {
            for _ in 0 ..< total / chunk.count { try? await host.send(chunk) }
        }
        try await done.wait(timeout: 120)
        let seconds = Double(start.duration(to: .now).components.attoseconds) / 1e18 + Double(start.duration(to: .now).components.seconds)
        let metrics = await host.metrics()
        print(String(format: "throughput: relay=%@ %.1f MB/s (%.1f Mbit/s), rtt %@ ms", relay ? "yes" : "no", Double(total) / seconds / 1e6,
                     Double(total) * 8 / seconds / 1e6, metrics.rttMs.map { String(format: "%.0f", $0) } ?? "-"))
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) -> Int { lock.withLock { count += n; return count } }
}
