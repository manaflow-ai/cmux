import CmuxLink
import CmuxLinkTesting
import CmuxMobileLink
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation

struct TimeoutError: Error {}

func within<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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

/// A hand-driven Mac for client tests: one link session over loopback; the
/// test reads and writes raw A0 records on the channels the phone opens.
struct ScriptedMac {
    static let fast = LinkConfiguration(
        handshakeTimeout: .seconds(2),
        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
        maxConnectAttempts: 100,
        resumeWindow: .seconds(30)
    )

    let host: LinkHost
    let phone: LinkSession
    let session: LinkSession

    static func make() async throws -> ScriptedMac {
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
        let session = try await within {
            for await session in sessions { return session }
            throw TimeoutError()
        }
        return ScriptedMac(host: host, phone: phone, session: session)
    }

    func shutdown() async {
        await phone.close()
        await host.close()
    }

    func acceptReliable() async throws -> MobileChannel {
        let incoming = await session.incomingChannels()
        let link = try await within {
            for await channel in incoming where channel.descriptor.reliability.isReliable { return channel }
            throw TimeoutError()
        }
        return MobileChannel(id: ScriptedOpener.channelID, link: link)
    }

    static func next(_ channel: MobileChannel) async throws -> MobileInbound {
        try await within { await channel.receive() }
    }

    /// The next binary record decoded as a desktop payload (skipping lane feedback).
    static func nextPayload(_ channel: MobileChannel) async throws -> DesktopPayload {
        while true {
            switch try await next(channel) {
            case .binary(let data, _): return try DesktopPayload(record: data)
            case .json, .gap: continue
            case .closed: throw TimeoutError()
            }
        }
    }
}

/// Opens `rd` channels on the scripted Mac's loopback link with A0 id 7.
struct ScriptedOpener: RemoteDesktopChannelOpener {
    static let channelID: UInt32 = 7
    let link: LinkSession

    func openChannel(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel {
        let channel = MobileChannel(id: Self.channelID, link: try await link.openChannel(
            ChannelDescriptor(stream: request.stream, reliability: .reliableOrdered, priority: request.priority)))
        try await channel.send(frame: .channelOpen(ChannelOpenFrame(channel: Self.channelID, kind: request.kind,
                                                                    channelClass: request.channelClass,
                                                                    window: request.window, params: request.params)))
        guard case .json(let value) = await channel.receive(), let frame = try? MobileFrame(value: value) else {
            throw MobileLinkClientError.linkLost
        }
        switch frame {
        case .channelOpened(let opened): return MobileOpenedChannel(channel: channel, opened: opened, generation: 1)
        case .channelRefused(let refused):
            throw MobileLinkClientError.refused(code: refused.code, message: refused.message, retryable: refused.retryable)
        default: throw MobileLinkClientError.protocolViolation("unexpected")
        }
    }

    func openDatagramLane(pairedWith channel: MobileOpenedChannel) async throws -> MobileDatagramLane {
        try await MobileDatagramLane.open(on: link, pairedWith: channel.channel.id)
    }
}
