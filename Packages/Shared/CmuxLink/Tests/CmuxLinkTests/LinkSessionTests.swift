import CmuxLink
import CmuxLinkTesting
import Foundation
import Testing

@Suite("LinkSession behaviors")
struct LinkSessionTests {
    static func payload(_ index: Int) -> Data { Data("m\(index)".utf8) }

    @Test("partial reliability delivers newest first and drops older arrivals")
    func partialNewestWins() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let descriptor = ChannelDescriptor(
            stream: "cursor", reliability: .partial(maxLifetime: .seconds(10)), priority: .media, budgetBytes: 1_000
        )
        let (channel, remote) = try await pair.openPair(descriptor, hostSession: hostSession)
        // Declared on the transport before sending (non-reliable sends drop
        // while a channel is not yet open).
        try await remote.send(Data("ready".utf8))
        guard case .message? = try await SessionTestPair.next(channel) else { Issue.record("no ready"); return }
        for index in 1...50 { try await channel.send(Self.payload(index)) }
        var revisions: [UInt64] = []
        while revisions.last != 50 {
            guard case let .message(message)? = try await SessionTestPair.next(remote) else { break }
            revisions.append(message.revision)
        }
        #expect(revisions == revisions.sorted())
        #expect(Set(revisions).count == revisions.count)
        #expect(revisions.last == 50)
        await pair.shutdown()
    }

    @Test("an unreliable channel drops the oldest unread messages past its budget")
    func unreliableInboundBudget() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let descriptor = ChannelDescriptor(
            stream: "video-hints", reliability: .unreliableUnordered, priority: .media, budgetBytes: 10
        )
        let (channel, remote) = try await pair.openPair(descriptor, hostSession: hostSession)
        try await remote.send(Data("ready".utf8))
        guard case .message? = try await SessionTestPair.next(channel) else { Issue.record("no ready"); return }
        for index in 0..<20 { try await channel.send(Data([UInt8(index), 0, 0, 0, 0])) }
        // A reliable marker on another channel proves the unreliable frames arrived.
        let (marker, markerRemote) = try await pair.openPair(
            ChannelDescriptor(stream: "marker", reliability: .reliableOrdered, priority: .bulk), hostSession: hostSession
        )
        try await marker.send(Data("done".utf8))
        _ = try await SessionTestPair.next(markerRemote)
        var kept: [UInt8] = []
        for _ in 0..<2 {
            guard case let .message(message)? = try await SessionTestPair.next(remote) else { break }
            kept.append(message.payload[0])
        }
        #expect(kept == [18, 19])
        await pair.shutdown()
    }

    @Test("bulk and media are refused on the control-sized relay")
    func relayIsControlSized() async throws {
        let pair = try await SessionTestPair(carriers: {
            [$0.carrier(kind: .doRelay, path: .relay, capabilities: .controlSized)]
        })
        let bulk = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "files", reliability: .reliableOrdered, priority: .bulk)
        )
        await #expect(throws: LinkError.unsupportedOnPath(.relay)) { try await bulk.send(Data("x".utf8)) }
        await #expect(throws: LinkError.unsupportedOnPath(.relay)) {
            _ = try await pair.dialer.publishMediaTrack(MediaTrackDescriptor(id: "v", kind: .video, label: "browser"))
        }
        let control = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "ops", reliability: .reliableOrdered, priority: .control)
        )
        await #expect(throws: LinkError.messageTooLarge(size: 20_000, limit: 16 * 1024 - LinkFrame.dataOverhead)) {
            try await control.send(Data(count: 20_000))
        }
        try await control.send(Data(count: 1_000))
        #expect(await pair.dialer.badge?.shouldShow == true)
        await pair.shutdown()
    }

    @Test("RTT above the threshold degrades the link and recovers")
    func degradedByRTT() async throws {
        let pair = try await SessionTestPair()
        await pair.network.reportRTT(.milliseconds(400))
        try await SessionTestPair.waitFor(pair.dialer) { $0 == .degraded(LinkPath(kind: .direct, carrier: .direct), .highLatency) }
        #expect(await pair.dialer.badge?.rtt == .milliseconds(400))
        await pair.network.reportRTT(.milliseconds(10))
        try await SessionTestPair.waitFor(pair.dialer) { $0 == .connected(LinkPath(kind: .direct, carrier: .direct)) }
        await pair.shutdown()
    }

    @Test("terminal output can adapt after an input-priority channel is promoted")
    func promotedTerminalUsesRenderBudget() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let descriptor = ChannelDescriptor(
            stream: "terminal/test", reliability: .reliableOrdered, priority: .input, budgetBytes: 64 * 1024
        )
        let (_, hostChannel) = try await pair.openPair(descriptor, hostSession: hostSession)
        await pair.network.reportRTT(.milliseconds(200))
        await hostChannel.setSendPriority(.render, budgetBytes: ChannelDescriptor.defaultBudget(for: .render))

        let frame = Data(repeating: 0x41, count: 200_000)
        // The declared input budget is 64 KiB. At 200 ms RTT the adaptive
        // render budget is 500 KiB, so two frames fit before the peer consumes.
        try await SessionTestPair.within(.seconds(1)) { try await hostChannel.send(frame) }
        try await SessionTestPair.within(.seconds(1)) { try await hostChannel.send(frame) }
        await pair.shutdown()
    }

    @Test("gives up after the attempt budget")
    func unreachable() async throws {
        var configuration = SessionTestPair.fast
        configuration.maxConnectAttempts = 3
        let pair = try await SessionTestPair(configuration: configuration, connect: false)
        await pair.network.setRefusing(.direct, true)
        await pair.dialer.connect()
        try await SessionTestPair.waitFor(pair.dialer) { $0 == .closed(.unreachable(attempts: 3)) }
        await #expect(throws: LinkError.closed(.unreachable(attempts: 3))) {
            _ = try await pair.dialer.openChannel(ChannelDescriptor(stream: "x", reliability: .reliableOrdered, priority: .input))
        }
        await pair.shutdown()
    }

    @Test("a network change retries at once instead of waiting out the backoff")
    func networkChangeRetries() async throws {
        var configuration = SessionTestPair.fast
        configuration.backoff = Backoff(initial: .seconds(60), maximum: .seconds(60))
        let pair = try await SessionTestPair(configuration: configuration, connect: false)
        await pair.network.setRefusing(.direct, true)
        await pair.dialer.connect()
        try await SessionTestPair.waitFor(pair.dialer) { $0 == .connecting(attempt: 2) }
        await pair.network.setRefusing(.direct, false)
        await pair.dialer.networkDidChange()
        try await SessionTestPair.waitFor(pair.dialer, timeout: .seconds(2)) { $0.isLive }
        await pair.shutdown()
    }

    @Test("upgrades relay to direct without losing the stream")
    func makeBeforeBreakUpgrade() async throws {
        let pair = try await SessionTestPair(carriers: {
            [$0.carrier(kind: .direct, path: .direct), $0.carrier(kind: .doRelay, path: .relay)]
        }, connect: false)
        await pair.network.setRefusing(.direct, true)
        await pair.dialer.connect()
        try await SessionTestPair.waitFor(pair.dialer) { $0.path?.kind == .relay }
        let hostSession = try await pair.nextHostSession()
        let (channel, remote) = try await pair.openPair(
            ChannelDescriptor(stream: "term", reliability: .reliableOrdered, priority: .render), hostSession: hostSession
        )
        let sender = Task {
            for index in 1...200 { try await channel.send(Self.payload(index)) }
        }
        await pair.network.setRefusing(.direct, false)
        await pair.dialer.networkDidChange()
        var revisions: [UInt64] = []
        while revisions.count < 200 {
            guard case let .message(message)? = try await SessionTestPair.next(remote) else { break }
            #expect(message.payload == Self.payload(Int(message.revision)))
            revisions.append(message.revision)
        }
        try await sender.value
        #expect(revisions == Array(1...200))
        try await SessionTestPair.waitFor(pair.dialer) { $0.path?.kind == .direct }
        #expect(await pair.host.activeSessionCount == 1)
        await pair.shutdown()
    }

    @Test("a restarted host starts a new epoch and channels report the gap")
    func hostRestart() async throws {
        let pair = try await SessionTestPair()
        let first = try await pair.nextHostSession()
        let (channel, remote) = try await pair.openPair(
            ChannelDescriptor(stream: "term", reliability: .reliableOrdered, priority: .render), hostSession: first
        )
        try await remote.send(Data("before".utf8))
        guard case .message? = try await SessionTestPair.next(channel) else { Issue.record("no message"); return }
        let oldEpoch = await pair.dialer.currentEpoch

        // The host process dies: a new acceptor and host, the old transports drop.
        let acceptor = await pair.network.replaceAcceptor()
        let restarted = LinkHost(acceptor: acceptor, configuration: SessionTestPair.fast)
        await restarted.start()
        let sessions = await restarted.sessions()
        await pair.network.dropAll()

        let second = try await SessionTestPair.within(.seconds(5)) { () -> LinkSession in
            for await session in sessions { return session }
            throw CancellationError()
        }
        guard case let .gap(gap)? = try await SessionTestPair.next(channel) else {
            Issue.record("no gap after host restart")
            return
        }
        #expect(gap.reason == .newEpoch)
        #expect(gap.lastDelivered.revision == 1)
        #expect(await pair.dialer.currentEpoch != oldEpoch)
        let incoming = await second.incomingChannels()
        let reopened = try await SessionTestPair.within(.seconds(5)) { () -> LinkChannel in
            for await channel in incoming { return channel }
            throw CancellationError()
        }
        try await reopened.send(Data("after".utf8))
        guard case let .message(message)? = try await SessionTestPair.next(channel) else {
            Issue.record("no message after restart")
            return
        }
        #expect(message.revision == 1)
        #expect(message.payload == Data("after".utf8))
        await restarted.close()
        await pair.shutdown()
    }

    @Test("media tracks reach the peer and end with the transport")
    func mediaTracks() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let tracks = await pair.dialer.incomingMediaTracks()
        let published = try await hostSession.publishMediaTrack(
            MediaTrackDescriptor(id: "tab-1", kind: .video, label: "browser/tab-1")
        )
        let received = try await SessionTestPair.within(.seconds(5)) { () -> MediaTrackHandle in
            for await track in tracks { return track }
            throw CancellationError()
        }
        #expect(received.descriptor == published.descriptor)
        let sink = CollectingSink()
        await received.attach(sink)
        await published.push(MediaFrame(timestamp: .milliseconds(16), width: 4, height: 2, payload: .encoded(Data([1]))))
        #expect(sink.frames == 1)
        let states = await received.states()
        await pair.network.dropAll()
        let ended = try await SessionTestPair.within(.seconds(5)) { () -> Bool in
            for await state in states where state == .ended { return true }
            return false
        }
        #expect(ended)
        await pair.shutdown()
    }

    @Test("flush waits until the peer consumed everything")
    func flush() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let (channel, remote) = try await pair.openPair(
            ChannelDescriptor(stream: "ops", reliability: .reliableOrdered, priority: .control), hostSession: hostSession
        )
        for index in 1...5 { try await channel.send(Self.payload(index)) }
        let flushed = Task { try await channel.flush() }
        for _ in 1...5 { _ = try await SessionTestPair.next(remote) }
        try await SessionTestPair.within(.seconds(5)) { try await flushed.value }
        #expect(await remote.cursor().revision == 5)
        await pair.shutdown()
    }

    @Test("cursors carry the session epoch, including channels opened before connecting")
    func cursorEpoch() async throws {
        let pair = try await SessionTestPair(connect: false)
        let early = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "early", reliability: .reliableOrdered, priority: .render)
        )
        await pair.dialer.connect()
        try await SessionTestPair.waitFor(pair.dialer) { $0.isLive }
        let hostSession = try await pair.nextHostSession()
        let incoming = await hostSession.incomingChannels()
        let remote = try await SessionTestPair.within(.seconds(5)) { () -> LinkChannel in
            for await channel in incoming { return channel }
            throw CancellationError()
        }
        try await remote.send(Self.payload(1))
        _ = try await SessionTestPair.next(early)
        let epoch = await pair.dialer.currentEpoch
        #expect(epoch != 0)
        #expect(await early.cursor() == StreamCursor(stream: "early", epoch: epoch, revision: 1))
        await pair.shutdown()
    }

    @Test("channel creation is bounded by the session configuration")
    func channelCapacity() async throws {
        var configuration = SessionTestPair.fast
        configuration.maxChannels = 1
        let pair = try await SessionTestPair(configuration: configuration)
        _ = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "first", reliability: .reliableOrdered, priority: .control)
        )
        await #expect(throws: LinkError.capacityExceeded(resource: "channels", limit: 1)) {
            _ = try await pair.dialer.openChannel(
                ChannelDescriptor(stream: "second", reliability: .reliableOrdered, priority: .control)
            )
        }
        await pair.shutdown()
    }

    @Test("incoming channels and media tracks do not accumulate before subscription")
    func pendingIncomingResourcesAreBounded() async throws {
        var configuration = SessionTestPair.fast
        configuration.maxPendingIncomingChannels = 1
        configuration.maxPendingIncomingMediaTracks = 1
        let pair = try await SessionTestPair(configuration: configuration)
        let hostSession = try await pair.nextHostSession()

        _ = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "first", reliability: .reliableOrdered, priority: .control)
        )
        let second = try await pair.dialer.openChannel(
            ChannelDescriptor(stream: "second", reliability: .reliableOrdered, priority: .control)
        )
        // Opening only queues the declaration. Wait for the peer to reject
        // the excess handle before subscribing and draining its pending queue.
        #expect(try await SessionTestPair.next(second) == .closed(.remote))
        let channels = await hostSession.incomingChannels()
        let first = try await SessionTestPair.within(.seconds(5)) { () -> LinkChannel in
            for await channel in channels { return channel }
            throw CancellationError()
        }
        #expect(first.stream == "first")
        await #expect(throws: TimeoutError.self) {
            _ = try await SessionTestPair.within(.milliseconds(100)) { () -> LinkChannel in
                for await channel in channels { return channel }
                throw CancellationError()
            }
        }

        _ = try await hostSession.publishMediaTrack(
            MediaTrackDescriptor(id: "track-1", kind: .video, label: "one")
        )
        let secondTrack = try await hostSession.publishMediaTrack(
            MediaTrackDescriptor(id: "track-2", kind: .video, label: "two")
        )
        // Media publication also returns before the receiving session handles
        // it. Rejection ends the loopback track on both sides.
        let rejectedTrackEnded = try await SessionTestPair.within(.seconds(5)) { () -> Bool in
            for await state in await secondTrack.states() where state == .ended { return true }
            return false
        }
        #expect(rejectedTrackEnded)
        let tracks = await pair.dialer.incomingMediaTracks()
        let firstTrack = try await SessionTestPair.within(.seconds(5)) { () -> MediaTrackHandle in
            for await track in tracks { return track }
            throw CancellationError()
        }
        #expect(firstTrack.id == "track-1")
        await #expect(throws: TimeoutError.self) {
            _ = try await SessionTestPair.within(.milliseconds(100)) { () -> MediaTrackHandle in
                for await track in tracks { return track }
                throw CancellationError()
            }
        }
        await pair.shutdown()
    }
}

final class CollectingSink: MediaFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var frames: Int { lock.withLock { count } }

    func receive(_ frame: MediaFrame) {
        lock.withLock { count += 1 }
    }
}
