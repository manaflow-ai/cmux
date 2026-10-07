import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation
import Testing

/// A host on a loopback network plus a dialing phone with a paired key.
struct PhoneHarness {
    static let hostID = "h_mac1"
    static let userID = "u_alice"
    static let install = "in_phone1"

    static let fast = LinkConfiguration(
        handshakeTimeout: .seconds(2),
        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
        maxConnectAttempts: 100,
        resumeWindow: .seconds(30)
    )

    let network: LoopbackNetwork
    let host: MobileHost
    let daemon: FakeDaemon
    let store: StaticTrustStore
    let phone: LinkSession
    let key: P256.Signing.PrivateKey

    init(devices: ((P256.Signing.PrivateKey) -> [PairedDevice])? = nil, handlers: MobileChannelHandlers = MobileChannelHandlers(),
         daemon: FakeDaemon = FakeDaemon(),
         authorizer: (any MobileDeviceAuthorizer)? = nil, key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
         carrierIdentity: LinkPeerIdentity? = nil, keyResolver: (any CarrierKeyResolver)? = nil) async throws {
        let paired = devices?(key) ?? [PairedDevice(install: Self.install, userID: Self.userID, keyID: "k1",
                                                     publicKey: key.publicKey.x963Representation)]
        let store = StaticTrustStore(devices: paired)
        let network = LoopbackNetwork()
        let host = MobileHost(
            configuration: MobileHostConfiguration(hostID: Self.hostID, accountUserID: Self.userID),
            acceptor: carrierIdentity.map { IdentifiedAcceptor(inner: network.acceptor, identity: $0) } ?? network.acceptor,
            daemon: daemon,
            authorizer: authorizer ?? TrustStoreAuthorizer(hostID: Self.hostID, accountUserID: Self.userID, store: store),
            handlers: handlers, linkConfiguration: Self.fast, workspaceStartSeq: 1000, keyResolver: keyResolver)
        await host.start()
        let phone = LinkSession(
            peer: LinkPeer(hostID: Self.hostID),
            selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
            configuration: Self.fast)
        await phone.connect()
        self.network = network
        self.host = host
        self.daemon = daemon
        self.store = store
        self.phone = phone
        self.key = key
    }

    func shutdown() async {
        await phone.close()
        await host.stop()
    }

    // MARK: Session

    func helloJSON(caps: [String] = ["device-proof", "read"], proof: DeviceProof?) throws -> JSONValue {
        let hello = HelloFrame(caps: caps, client: HelloClient(install: Self.install, platform: "ios", appVersion: "1.0"))
        guard case .object(var object) = try MobileFrame.hello(hello).jsonValue else { throw TimeoutError() }
        if let proof { object["auth"] = proof.jsonValue }
        return .object(object)
    }

    func proof(sessionID: UUID? = nil, issuedAt: Int64? = nil, keyID: String = "k1") throws -> DeviceProof {
        let key = key
        return try DeviceProof(install: Self.install, keyID: keyID,
                               issuedAt: issuedAt ?? Int64(Date().timeIntervalSince1970 * 1000),
                               hostID: Self.hostID, sessionID: sessionID ?? phone.sessionID) { data in
            try key.signature(for: data).rawRepresentation
        }
    }

    /// Opens the session channel and sends hello; returns the host's answer.
    @discardableResult
    func hello(_ value: JSONValue? = nil) async throws -> (MobileChannel, JSONValue) {
        let link = try await phone.openChannel(ChannelDescriptor(stream: "cmux.mobile/session", reliability: .reliableOrdered,
                                                                 priority: .control))
        let channel = MobileChannel(id: 0, link: link)
        try await channel.send(json: try value ?? helloJSON(proof: proof()))
        let reply = try await Self.nextJSON(channel)
        return (channel, reply)
    }

    /// Opens an A0 channel and returns it with the host's first record.
    func open(_ kind: ChannelKind, id: UInt32, params: [String: JSONValue] = [:], window: UInt32 = 262_144,
              budget: Int? = nil, priority: ChannelPriority = .control) async throws -> (MobileChannel, JSONValue) {
        let link = try await phone.openChannel(ChannelDescriptor(stream: "\(kind.rawValue)/\(id)", reliability: .reliableOrdered,
                                                                 priority: priority, budgetBytes: budget))
        let channel = MobileChannel(id: id, link: link)
        let open = ChannelOpenFrame(channel: id, kind: kind, channelClass: .interactive, window: window, params: params)
        try await channel.send(frame: .channelOpen(open))
        return (channel, try await Self.nextJSON(channel))
    }

    static func next(_ channel: MobileChannel) async throws -> MobileInbound {
        try await within { await channel.receive() }
    }

    static func nextJSON(_ channel: MobileChannel) async throws -> JSONValue {
        let inbound = try await next(channel)
        guard case .json(let value) = inbound else {
            Issue.record("expected JSON, got \(inbound)")
            throw TimeoutError()
        }
        return value
    }

    static func terminalParams(_ terminal: String = "term_x1") -> [String: JSONValue] {
        (try? JSONValue(encoding: TerminalChannelParams(terminal: terminal, viewport: TerminalViewport(cols: 46, rows: 38),
                                                         visible: true, counts: true,
                                                         snapshot: TerminalSnapshotSupport(versions: [1]))))?.objectValue ?? [:]
    }
}
