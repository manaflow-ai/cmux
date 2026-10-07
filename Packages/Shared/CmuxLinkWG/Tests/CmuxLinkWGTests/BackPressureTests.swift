import CmuxLink
import CmuxLinkTesting
import CmuxLinkWG
import CmuxLinkWGTesting
import Foundation
import Testing

/// E1: a consumer that stops reading never makes the transport buffer
/// without bound.
@Suite("WebRTC-WG back-pressure", .serialized)
struct BackPressureTests {
    @Test func unreliableFloodIntoASlowConsumerIsBoundedAndDropped() async throws {
        let pair = try await TransportPair.connect()
        let lane = TransportLane(reliability: .unreliableUnordered, priority: .media)
        let size = 1000
        let total = 20_000
        for index in 0..<total {
            try await pair.dialer.send(TransportFrame(lane: lane, bytes: TransportTests.payload(index, size: size)))
        }
        // Test-only settle: let the in-memory underlay deliver what it will.
        try await Task.sleep(for: .milliseconds(500))
        let queued = try await Self.drainQuietly(pair.host)
        #expect(queued * size <= 2 << 20, "\(queued) datagrams (\(queued * size >> 10) KiB) buffered for a consumer that read nothing")
        await pair.shutdown()
    }

    /// Reads frames until none arrives for 200 ms; returns the count.
    static func drainQuietly(_ transport: any LinkTransport) async throws -> Int {
        let counter = FrameCounter()
        let events = transport.events
        let reader = Task {
            for await event in events {
                if case .frame = event { await counter.increment() }
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

actor FrameCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
