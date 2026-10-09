import CmuxLink
import CmuxLinkTesting
import Foundation
import Testing

/// Regressions for the correctness review of the first CmuxLink pass.
@Suite("Review regressions")
struct ReviewRegressionTests {
    static let render = ChannelDescriptor(stream: "term", reliability: .reliableOrdered, priority: .render, budgetBytes: 4 * 1024)

    @Test("a sender blocked on credit keeps back-pressure across a reconnect and wakes on consumption")
    func creditSurvivesReconnect() async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let (channel, remote) = try await pair.openPair(Self.render, hostSession: hostSession)
        for index in 1...4 { try await channel.send(Data(repeating: UInt8(index), count: 1024)) }
        let fifthSent = AsyncQueue<Bool>()
        let fifth = Task {
            try await channel.send(Data(repeating: 5, count: 1024))
            await fifthSent.push(true)
        }
        // Let the host receive (not consume) messages 1-4 before the drop.
        try await Task.sleep(for: .milliseconds(50))
        await pair.network.dropAll()
        try await SessionTestPair.waitFor(pair.dialer) { if case .reconnecting = $0 { true } else { false } }
        try await SessionTestPair.waitFor(pair.dialer) { $0.isLive }
        try await Task.sleep(for: .milliseconds(100))
        // Received but unconsumed data still holds the budget.
        #expect(await fifthSent.count == 0)
        var revisions: [UInt64] = []
        for _ in 1...5 {
            guard case let .message(message)? = try await SessionTestPair.next(remote) else { break }
            revisions.append(message.revision)
        }
        try await SessionTestPair.within(.seconds(5)) { try await fifth.value }
        #expect(revisions == [1, 2, 3, 4, 5])
        await pair.shutdown()
    }

    @Test("a replaced host session stays registered after the old one closes")
    func hostKeepsReplacement() async throws {
        let pair = try await SessionTestPair()
        let first = try await pair.nextHostSession()
        // A second hello for the same session id with epoch 0 (the first
        // welcome was lost) replaces the session.
        let transport = try await pair.network.carrier(kind: .direct, path: .direct).connect(to: LinkPeer(hostID: "host"))
        let hello = LinkFrame.hello(sessionID: pair.dialer.sessionID, epoch: 0)
        try await transport.send(TransportFrame(lane: .control, bytes: hello.encoded()))
        let second = try await pair.nextHostSession()
        #expect(second !== first)
        try await SessionTestPair.waitFor(first) { $0.isClosed }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await pair.host.activeSessionCount == 1)
        await transport.close()
        await pair.shutdown()
    }

    @Test("a closed channel is not re-delivered when its opener re-declares it")
    func noPhantomChannel() async throws {
        let pair = try await SessionTestPair(conditions: NetworkConditions(latency: .milliseconds(40)))
        let hostSession = try await pair.nextHostSession()
        let incoming = AsyncQueue<LinkChannel>()
        let stream = await hostSession.incomingChannels()
        Task { for await channel in stream { await incoming.push(channel) } }
        let channel = try await pair.dialer.openChannel(Self.render)
        let remote = try await SessionTestPair.within(.seconds(5)) { try #require(await incoming.next()) }
        try await channel.send(Data("hello".utf8))
        _ = try await SessionTestPair.next(remote)
        // The dialer closes; the host sees it and closes too; the host's echo
        // is in flight when the path dies.
        await channel.close()
        guard case .closed(.remote)? = try await SessionTestPair.next(remote) else {
            Issue.record("host did not see the close")
            return
        }
        await remote.close()
        await pair.network.dropAll()
        try await SessionTestPair.waitFor(pair.dialer) { if case .reconnecting = $0 { true } else { false } }
        try await SessionTestPair.waitFor(pair.dialer) { $0.isLive }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await incoming.count == 0)
        await pair.shutdown()
    }

    @Test("a retained frame too large for the fallback path stalls instead of flapping")
    func oversizedReplayStalls() async throws {
        let pair = try await SessionTestPair(carriers: {
            [$0.carrier(kind: .direct, path: .direct), $0.carrier(kind: .doRelay, path: .relay, capabilities: .controlSized)]
        })
        let hostSession = try await pair.nextHostSession()
        let big = ChannelDescriptor(stream: "snapshot", reliability: .reliableOrdered, priority: .render, budgetBytes: 1 << 20)
        let (channel, remote) = try await pair.openPair(big, hostSession: hostSession)
        let states = AsyncQueue<LinkState>()
        let stateStream = await pair.dialer.states()
        Task { for await state in stateStream { await states.push(state) } }
        await pair.network.setRefusing(.direct, true)
        await pair.network.dropAll()
        try await channel.send(Data(repeating: 7, count: 100 * 1024))
        try await SessionTestPair.waitFor(pair.dialer) { $0.path?.kind == .relay }
        let relayConnects = await pair.network.connectCount(.doRelay)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await pair.network.connectCount(.doRelay) == relayConnects)
        #expect(await pair.dialer.state.path?.kind == .relay)
        await pair.network.setRefusing(.direct, false)
        await pair.dialer.networkDidChange()
        guard case let .message(message)? = try await SessionTestPair.next(remote) else {
            Issue.record("stalled frame never delivered")
            return
        }
        #expect(message.payload.count == 100 * 1024)
        #expect(await pair.dialer.state.path?.kind == .direct)
        await pair.shutdown()
    }

    @Test("make-before-break never reports reconnecting")
    func upgradeIsSilent() async throws {
        let pair = try await SessionTestPair(carriers: {
            [$0.carrier(kind: .direct, path: .direct), $0.carrier(kind: .doRelay, path: .relay)]
        }, connect: false)
        await pair.network.setRefusing(.direct, true)
        await pair.dialer.connect()
        try await SessionTestPair.waitFor(pair.dialer) { $0.path?.kind == .relay }
        let seen = AsyncQueue<LinkState>()
        let stream = await pair.dialer.states()
        Task { for await state in stream { await seen.push(state) } }
        let directBefore = await pair.network.connectCount(.direct)
        await pair.network.setRefusing(.direct, false)
        await pair.dialer.networkDidChange()
        try await SessionTestPair.waitFor(pair.dialer) { $0.path?.kind == .direct }
        try await Task.sleep(for: .milliseconds(50))
        while await seen.count > 0, let state = await seen.next() {
            if case .reconnecting = state { Issue.record("upgrade reported \(state)") }
        }
        #expect(await pair.network.connectCount(.direct) == directBefore + 1)
        await pair.shutdown()
    }

    @Test("the selector returns without waiting for a loser that ignores cancellation")
    func selectorDoesNotDrainLosers() async throws {
        let network = LoopbackNetwork()
        let selector = PathSelector(carriers: [
            network.carrier(kind: .direct, path: .direct), StubbornCarrier(),
        ])
        let start = ContinuousClock.now
        let transport = try await selector.race(to: LinkPeer(hostID: "host"))
        #expect(await transport.path.kind == .direct)
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}

/// A carrier whose connect ignores cancellation for two seconds.
struct StubbornCarrier: LinkCarrier {
    let kind = CarrierKind(rawValue: "stubborn")
    let candidatePaths: [PathKind] = [.relay]

    func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
        throw LoopbackError.refused
    }
}
