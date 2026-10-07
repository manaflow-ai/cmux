import CmuxBrowserStream
import CmuxLink
import CmuxLinkTesting
import CmuxMobileWire
import Foundation

struct TimeoutError: Error {}

/// A hand-driven Mac for client tests: accepts one link session over
/// loopback and lets the test read and write raw A0 records.
struct ScriptedHost {
    static let fast = LinkConfiguration(
        handshakeTimeout: .seconds(2),
        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
        maxConnectAttempts: 100,
        resumeWindow: .seconds(30)
    )

    let host: LinkHost
    let phone: LinkSession
    let hostSession: LinkSession

    static func make() async throws -> ScriptedHost {
        let network = LoopbackNetwork()
        let host = LinkHost(acceptor: network.acceptor, configuration: fast)
        await host.start()
        let phone = LinkSession(
            peer: LinkPeer(hostID: "h_mac1"),
            selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
            configuration: fast)
        await phone.connect()
        let sessions = await host.sessions()
        let session = try await Self.within {
            for await session in sessions { return session }
            throw TimeoutError()
        }
        return ScriptedHost(host: host, phone: phone, hostSession: session)
    }

    func shutdown() async {
        await phone.close()
        await host.close()
    }

    /// The next channel the phone opened (reliable ones only).
    func acceptReliable() async throws -> LinkChannel {
        let incoming = await hostSession.incomingChannels()
        return try await Self.within {
            for await channel in incoming where channel.descriptor.reliability.isReliable { return channel }
            throw TimeoutError()
        }
    }

    static func next(_ channel: LinkChannel) async throws -> StreamRecord {
        try await within {
            var iterator = channel.events.makeAsyncIterator()
            guard case .message(let message)? = await iterator.next() else { throw TimeoutError() }
            return try StreamRecord(decoding: message.payload)
        }
    }

    static func within<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
}

final class ScriptedSessionLink: MobileSessionLink {
    let link: any CmuxLink

    init(link: any CmuxLink) {
        self.link = link
    }

    func allocateChannelID() async -> UInt32 { 7 }
}
