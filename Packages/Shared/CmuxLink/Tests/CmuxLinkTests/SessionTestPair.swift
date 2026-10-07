import CmuxLink
import CmuxLinkTesting
import Foundation
import Testing

/// A dialer and host over a loopback network for session behavior tests.
struct SessionTestPair {
    let network: LoopbackNetwork
    let host: LinkHost
    let dialer: LinkSession
    let hostSessions: AsyncQueue<LinkSession>

    static let fast = LinkConfiguration(
        handshakeTimeout: .seconds(2),
        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
        maxConnectAttempts: 100,
        resumeWindow: .seconds(30),
        degradedRTT: .milliseconds(300)
    )

    init(
        carriers: (LoopbackNetwork) -> [LoopbackCarrier] = { [$0.carrier(kind: .direct, path: .direct)] },
        conditions: NetworkConditions? = nil,
        configuration: LinkConfiguration = Self.fast,
        policy: PathPolicy = PathPolicy(preferenceWindow: .milliseconds(10), upgradeRetry: nil),
        connect: Bool = true
    ) async throws {
        let network = LoopbackNetwork(conditions: conditions)
        let host = LinkHost(acceptor: network.acceptor, configuration: configuration)
        await host.start()
        let hostSessions = AsyncQueue<LinkSession>()
        let sessions = await host.sessions()
        Task {
            for await session in sessions { await hostSessions.push(session) }
        }
        let dialer = LinkSession(
            peer: LinkPeer(hostID: "host"),
            selector: PathSelector(carriers: carriers(network), policy: policy),
            configuration: configuration
        )
        self.network = network
        self.host = host
        self.dialer = dialer
        self.hostSessions = hostSessions
        if connect {
            await dialer.connect()
            try await Self.waitFor(dialer) { $0.isLive }
        }
    }

    static func waitFor(
        _ session: LinkSession,
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable (LinkState) -> Bool
    ) async throws {
        let states = await session.states()
        try await within(timeout) {
            for await state in states where predicate(state) { return }
            Issue.record("state stream ended")
        }
    }

    func nextHostSession() async throws -> LinkSession {
        let queue = hostSessions
        return try await Self.within(.seconds(5)) { try #require(await queue.next()) }
    }

    /// Opens a channel from the dialer and returns both ends.
    func openPair(_ descriptor: ChannelDescriptor, hostSession: LinkSession) async throws -> (LinkChannel, LinkChannel) {
        let local = try await dialer.openChannel(descriptor)
        let incoming = await hostSession.incomingChannels()
        let remote = try await Self.within(.seconds(5)) { () -> LinkChannel in
            for await channel in incoming where channel.stream == descriptor.stream { return channel }
            throw CancellationError()
        }
        return (local, remote)
    }

    static func next(_ channel: LinkChannel, timeout: Duration = .seconds(5)) async throws -> ChannelEvent? {
        try await within(timeout) {
            var iterator = channel.events.makeAsyncIterator()
            return await iterator.next()
        }
    }

    static func within<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func shutdown() async {
        await dialer.close()
        await host.close()
    }
}

struct TimeoutError: Error {}
