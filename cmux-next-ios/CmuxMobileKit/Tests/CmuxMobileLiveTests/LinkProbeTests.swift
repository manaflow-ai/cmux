import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link whose pong never comes back while the Mac's frames keep arriving
/// (a slow relay's queue): its probe says alive without a round trip.
final class BusyLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var probes = 0
    var isClosed: Bool { lock.withLock { closed } }
    var probeCount: Int { lock.withLock { probes } }

    init() {
        (states, continuation) = AsyncStream.makeStream(of: LinkState.self)
        continuation.yield(.connected(.wireGuard, .turnTLS, rttMillis: nil))
    }

    var connectedPath: LinkPathKind? { .turnTLS }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    /// The pong is stuck behind a full queue.
    func ping() async throws -> UInt32 {
        try await Task.sleep(for: .seconds(60))
        return 1
    }
    /// What the Rust link answers when frames arrive but the pong does not.
    func probe(timeout: Duration) async throws -> UInt32? {
        lock.withLock { probes += 1 }
        return nil
    }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

final class BusyDialer: MacLinkDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [BusyLink] = []
    var dials: Int { lock.withLock { links.count } }
    var first: BusyLink? { lock.withLock { links.first } }

    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink {
        let link = BusyLink()
        lock.withLock { links.append(link) }
        return link
    }
}

@MainActor
@Suite struct LinkProbeTests {
    /// The app's probes (the 15 s heartbeat, a foreground, a presence change)
    /// keep a link whose Mac is sending, even when its pong is late. Live on
    /// 2026-10-23 the phone closed such links ("peer closed the link" 22 to
    /// 24 s after link up, with the Mac's tunnel still delivering) and redialed
    /// for 4 to 9 s each time.
    @Test func aBusyLinkWithALatePongIsKept() async throws {
        let dialer = BusyDialer()
        let controller = LinkController(transport: .wireGuard, dialer: dialer) { _ in "token" }
        controller.endpoint = { mac in
            LinkEndpoint(baseURL: URL(string: "https://example.invalid")!, teamID: "t", deviceID: "d", macDeviceID: mac)
        }
        controller.send(.target(.init(macID: "m1", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.phase.isConnected)
        // A foreground probe (2 s) and a presence probe (1.5 s), as after a signaling reset.
        controller.send(.foreground)
        controller.send(.macSignaled)
        // Past both probes' timeouts (and the bound's grace): a ping-only probe would have failed by now.
        try await Task.sleep(for: .milliseconds(2700))
        #expect(controller.phase.isConnected, "\(controller.phase)")
        #expect(dialer.dials == 1)
        #expect(dialer.first?.isClosed == false)
        // The foreground's and the presence change's probes both ran (the adopt's
        // own foreground comes before the link counts as connected, so it probes nothing).
        #expect((dialer.first?.probeCount ?? 0) >= 2)
    }
}
