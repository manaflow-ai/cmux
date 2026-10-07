import CmuxLink
import CmuxLinkTesting
import CmuxMobileLink
import Foundation
import Testing

/// E1: datagram lanes a reader has not taken never pile up; a new lane
/// replaces the previous one and the replaced lane is closed.
@Suite("datagram lane back-pressure")
struct DatagramLaneBackPressureTests {
    @Test func unreadLanesKeepOnlyTheNewest() async throws {
        let configuration = LinkConfiguration(
            handshakeTimeout: .seconds(2),
            backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
            maxConnectAttempts: 100,
            resumeWindow: .seconds(30),
            degradedRTT: nil
        )
        let network = LoopbackNetwork()
        let host = LinkHost(acceptor: network.acceptor, configuration: configuration)
        await host.start()
        let dialer = LinkSession(
            peer: LinkPeer(hostID: "host"),
            selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                   policy: PathPolicy(preferenceWindow: .milliseconds(10), upgradeRetry: nil)),
            configuration: configuration
        )
        let states = await dialer.states()
        await dialer.connect()
        let live = await firstWithin(.seconds(5)) { () -> Bool in
            for await state in states where state.isLive { return true }
            return false
        }
        try #require(live == true)

        let anchor = try await dialer.openChannel(ChannelDescriptor(stream: "anchor", reliability: .reliableOrdered, priority: .control))
        let channel = MobileChannel(id: 7, link: anchor)
        var links: [LinkChannel] = []
        for index in 0..<40 {
            let link = try await dialer.openChannel(ChannelDescriptor(
                stream: "cmux.mobile/datagram/7/\(index)", reliability: .unreliableUnordered, priority: .media
            ))
            links.append(link)
            await channel.attachDatagramLane(link)
        }
        await channel.abort()
        var queued = 0
        for await _ in await channel.datagramLanes() { queued += 1 }
        #expect(queued == 1, "\(queued) lanes were queued for a reader that took none")
        let first = links[0]
        let closed = await firstWithin(.seconds(2)) { () -> Bool in
            var replaced = first.events.makeAsyncIterator()
            if case .closed? = await replaced.next() { return true }
            return false
        }
        #expect(closed == true, "the replaced lane was not closed")
        await dialer.close()
        await host.close()
    }
}

/// The operation's result, or nil after `limit` of real time (the operation
/// runs unstructured and is abandoned).
func firstWithin<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let (results, sink) = AsyncStream.makeStream(of: T?.self, bufferingPolicy: .bufferingNewest(1))
    let work = Task { sink.yield(await operation()) }
    let timer = Task {
        try? await Task.sleep(for: limit)
        sink.yield(nil)
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    for await result in results { return result }
    return nil
}
