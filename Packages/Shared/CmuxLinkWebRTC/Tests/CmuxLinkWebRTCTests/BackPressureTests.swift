import CmuxLink
import CmuxLinkWG
import CmuxLinkWGTesting
@_spi(Testing) import CmuxLinkWebRTC
import Foundation
import Testing

extension LiveWebRTCTests {
/// E1: a consumer that stops reading never makes the carrier buffer
/// without bound (reliable lanes: rawBackPressure in the conformance suite).
@Suite("WebRTC back-pressure")
struct BackPressureTests {
    @Test("a wg datagram flood into a consumer that reads nothing stays bounded")
    func datagramFloodIsBounded() async throws {
        let rig = WebRTCUnderlayRig()
        let endpoints = rig.endpoints()
        let incoming = endpoints.listener.incoming
        async let accepted: (any DatagramUnderlay)? = { for await underlay in incoming { return underlay }; return nil }()
        let dialed = try await within { try await endpoints.dialer.open(to: LinkPeer(hostID: WebRTCUnderlayRig.hostID)) }
        let host = try #require(await accepted)
        let datagram = Data(repeating: 7, count: 1200)
        let total = 20_000
        try await within(.seconds(30)) {
            for _ in 0..<total { try await dialed.send(datagram) }
        }
        // Test-only settle: let SCTP deliver what it will.
        try await Task.sleep(for: .milliseconds(500))
        let queued = try await Self.drainQuietly(host)
        #expect(queued * datagram.count <= 2 << 20, "\(queued) datagrams buffered for a consumer that read nothing")
        await dialed.close()
        await endpoints.stop()
    }

    /// Reads datagrams until none arrives for 200 ms; returns the count.
    static func drainQuietly(_ underlay: any DatagramUnderlay) async throws -> Int {
        let counter = DatagramCounter()
        let events = underlay.events
        let reader = Task {
            for await event in events {
                if case .datagram = event { await counter.increment() }
            }
        }
        defer { reader.cancel() }
        var last = -1
        while true {
            try await Task.sleep(for: .milliseconds(200))
            let now = await counter.count
            if now == last { return now }
            last = now
        }
    }
}
}

actor DatagramCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
