import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CmuxTerminalStream
import CryptoKit
import Foundation
import Testing

/// A software P-256 key standing in for the phone's Secure Enclave key.
struct SoftwareSigner: MobileDeviceSigner {
    let install: String
    let keyID: String
    let key: P256.Signing.PrivateKey

    func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

/// A real `MobileHost` (B5) with a scripted daemon on a loopback or lossy
/// network, and the phone's `MobileLinkClient` + `LinkTerminalByteSource`.
struct TerminalHarness {
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
    let daemon: ScriptedDaemon
    let store: StaticTrustStore
    let client: MobileLinkClient
    let source: LinkTerminalByteSource
    private let hosts: HostBox

    init(conditions: NetworkConditions? = nil, options: TerminalLinkOptions = TerminalLinkOptions(),
         clock: LinkClock = .continuous, daemon: ScriptedDaemon = ScriptedDaemon()) async {
        let key = P256.Signing.PrivateKey()
        let store = StaticTrustStore(devices: [PairedDevice(install: Self.install, userID: Self.userID, keyID: "k1",
                                                            publicKey: key.publicKey.x963Representation)])
        let network = LoopbackNetwork(conditions: conditions)
        let hosts = HostBox()
        await hosts.start(Self.makeHost(acceptor: network.acceptor, daemon: daemon, store: store))
        let carrier = network.carrier(kind: .direct, path: .direct)
        let client = MobileLinkClient(
            hostID: Self.hostID, signer: SoftwareSigner(install: Self.install, keyID: "k1", key: key),
            client: HelloClient(install: Self.install, platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: Self.hostID),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: Self.fast)
            })
        self.network = network
        self.daemon = daemon
        self.store = store
        self.client = client
        self.hosts = hosts
        source = LinkTerminalByteSource(terminal: "term_x1", client: client, options: options, clock: clock)
    }

    static func makeHost(acceptor: any LinkAcceptor, daemon: ScriptedDaemon, store: StaticTrustStore) -> MobileHost {
        MobileHost(configuration: MobileHostConfiguration(hostID: hostID, accountUserID: userID),
                   acceptor: acceptor, daemon: daemon,
                   authorizer: TrustStoreAuthorizer(hostID: hostID, accountUserID: userID, store: store),
                   linkConfiguration: fast, workspaceStartSeq: 1000)
    }

    /// The Mac's cmux restarted: a new link host (new epoch) behind the same address.
    func restartHost() async {
        let acceptor = await network.replaceAcceptor()
        await hosts.start(Self.makeHost(acceptor: acceptor, daemon: daemon, store: store))
        await network.dropAll()
    }

    func shutdown() async {
        await source.close()
        await client.close()
        await hosts.stopAll()
    }

    /// Opens the source and records its events.
    func open(cols: Int = 54, rows: Int = 44, visible: Bool = true) async throws -> EventLog {
        let stream = try await source.open(TerminalViewport(cols: cols, rows: rows, visible: visible))
        return EventLog(stream)
    }

    func nextAttachment() async throws -> ScriptedAttachment {
        try await within { try #require(await daemon.attachments.next()) }
    }
}

actor HostBox {
    private var hosts: [MobileHost] = []

    func start(_ host: MobileHost) async {
        hosts.append(host)
        await host.start()
    }

    func stopAll() async {
        for host in hosts { await host.stop() }
        hosts.removeAll()
    }
}
