import CmuxBrowserStream
import CmuxLink
import CmuxLinkTesting
import CmuxMobileLink
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
    let client: MobileLinkClient
    let hostSession: LinkSession

    /// A host that answers the phone's hello with `hello.ok` (it checks no proof).
    static func make() async throws -> ScriptedHost {
        let network = LoopbackNetwork()
        let host = LinkHost(acceptor: network.acceptor, configuration: fast)
        await host.start()
        let carrier = network.carrier(kind: .direct, path: .direct)
        let client = MobileLinkClient(
            hostID: "h_mac1", signer: UnsignedSigner(), client: HelloClient(install: "in_phone1", platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: "h_mac1"),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: fast)
            })
        let sessions = await host.sessions()
        async let hello = client.helloOK()
        let session = try await Self.within {
            for await session in sessions { return session }
            throw TimeoutError()
        }
        let scripted = ScriptedHost(host: host, client: client, hostSession: session)
        let sessionChannel = try await scripted.acceptReliable()
        _ = try await Self.next(sessionChannel)
        let ok = HelloOKFrame(version: 1, caps: ["device-proof"], serverTime: 0, maxFrame: 256 * 1024)
        try await sessionChannel.send(try StreamRecord.json(channel: 0, seq: 1, object: try MobileFrame.helloOK(ok).jsonValue).encoded)
        _ = try await hello
        return scripted
    }

    func shutdown() async {
        await client.close()
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

struct UnsignedSigner: MobileDeviceSigner {
    let install = "in_phone1"
    let keyID = "k1"

    func sign(_ message: Data) throws -> Data { Data(count: 64) }
}
