import CmuxLink
import CmuxLinkTesting
import Foundation

/// One connected dialer session and host, built from a rig's endpoints the
/// way the app wires them (`LinkSession` over a `PathSelector`, `LinkHost`
/// over the acceptor).
struct BenchFixture: BenchFixtureProtocol {
    let rig: any ConformanceHarness
    let dialer: LinkSession
    let host: LinkHost
    let hostSession: LinkSession
    let incoming: AsyncQueue<LinkChannel>
    /// From `connect()` to the dialer reporting a live path.
    let connectToLive: Duration

    static let configuration = LinkConfiguration(handshakeTimeout: .seconds(10), maxConnectAttempts: 4, degradedRTT: nil)

    static func connect(_ rig: any ConformanceHarness, limit: Duration = .seconds(20)) async throws -> BenchFixture {
        let endpoints = try await rig.makeEndpoints()
        let host = LinkHost(acceptor: endpoints.acceptor, configuration: configuration)
        await host.start()
        let dialer = LinkSession(
            peer: endpoints.peer,
            selector: PathSelector(carriers: endpoints.carriers, policy: PathPolicy(upgradeRetry: nil)),
            configuration: configuration
        )
        let sessions = await host.sessions()
        let states = await dialer.states()
        let clock = ContinuousClock()
        let start = clock.now
        await dialer.connect()
        let live = try await TimeLimit(limit).run { () -> Bool in
            for await state in states {
                if state.isLive { return true }
                if state.isClosed { return false }
            }
            return false
        }
        let connectToLive = clock.now - start
        guard live == true else {
            await dialer.close()
            await host.close()
            throw BenchError.setup("dialer did not connect (\(live == nil ? "timeout" : "closed"))")
        }
        guard let hostSession = try await TimeLimit(limit).run({
            for await session in sessions { return session }
            return nil
        }) ?? nil else {
            await dialer.close()
            await host.close()
            throw BenchError.setup("host saw no session")
        }
        let incoming = AsyncQueue<LinkChannel>()
        let channels = await hostSession.incomingChannels()
        Task {
            for await channel in channels { await incoming.push(channel) }
            await incoming.finish()
        }
        return BenchFixture(
            rig: rig, dialer: dialer, host: host, hostSession: hostSession,
            incoming: incoming, connectToLive: connectToLive
        )
    }

    /// Opens a channel from the dialer; returns (dialer end, host end).
    func openPair(_ descriptor: ChannelDescriptor) async throws -> BenchChannelPair {
        let local = try await dialer.openChannel(descriptor)
        let incoming = incoming
        guard let remote = try await TimeLimit(.seconds(10)).run({ await incoming.next() }) ?? nil else {
            throw BenchError.timeout("host did not see channel \(descriptor.stream)")
        }
        guard remote.stream == descriptor.stream else {
            throw BenchError.unexpected("host saw \(remote.stream), expected \(descriptor.stream)")
        }
        return BenchChannelPair(local: local, remote: remote)
    }

    func shutdown() async {
        await dialer.close()
        await host.close()
        await rig.tearDown()
    }
}
