import CmuxLink
import CmuxLinkTesting
import CmuxMobileFiles
import CmuxMobileHost
import CmuxMobileWire
import CryptoKit
import Foundation

/// A Mac (`MobileHost` with the C4 handlers on a throwaway home) and a phone
/// that dials it over a loopback network, optionally impaired.
final class FilesWorld: Sendable {
    static let hostID = "h_mac1"
    static let userID = "u_alice"
    static let install = "in_phone1"
    static let fast = LinkConfiguration(handshakeTimeout: .seconds(2),
                                        backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
                                        maxConnectAttempts: 200, resumeWindow: .seconds(30))

    let base: URL
    let home: URL
    let workspace: URL
    let phoneDirectory: URL
    let network: LoopbackNetwork
    let host: MobileHost
    let signer: TestSigner
    let connects = Counter()
    private let sessions = SessionBox()

    init(conditions: NetworkConditions? = nil, chunkBytes: Int = 32 * 1024,
         uploadHandler: (any MobileChannelHandler)? = nil) async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("c4f-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        workspace = home.appendingPathComponent("src/proj", isDirectory: true)
        phoneDirectory = base.appendingPathComponent("phone", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: phoneDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: home.appendingPathComponent("secret.txt"))
        let key = P256.Signing.PrivateKey()
        signer = TestSigner(key: key, install: Self.install)
        let store = StaticTrustStore(devices: [PairedDevice(install: Self.install, userID: Self.userID, keyID: "k1",
                                                            publicKey: key.publicKey.x963Representation)])
        let files = MobileFiles(
            configuration: MobileFilesConfiguration(homeDirectory: home, chunkBytes: chunkBytes, freeSpaceMarginBytes: 0),
            roots: StaticFileRoots([MobileFileRoot(id: "ws_a1", name: "proj", url: workspace, writable: true)]))
        var handlers = files.registering()
        if let uploadHandler { handlers.channels[.filesUpload] = uploadHandler }
        network = LoopbackNetwork(conditions: conditions)
        host = MobileHost(configuration: MobileHostConfiguration(hostID: Self.hostID, accountUserID: Self.userID),
                          acceptor: network.acceptor, daemon: NoDaemon(),
                          authorizer: TrustStoreAuthorizer(hostID: Self.hostID, accountUserID: Self.userID, store: store),
                          handlers: handlers, linkConfiguration: Self.fast)
        await host.start()
    }

    /// A fresh link session and started client session (one per call).
    func connect() async throws -> MobileClientSession {
        await connects.increment()
        let link = LinkSession(
            peer: LinkPeer(hostID: Self.hostID),
            selector: PathSelector(carriers: [network.carrier(kind: .direct, path: .direct)],
                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
            configuration: Self.fast)
        await link.connect()
        let session = MobileClientSession(link: link, hostID: Self.hostID, signer: signer)
        try await session.start()
        await sessions.add(link)
        return session
    }

    /// The connector a `MobileTransferManager` uses: a new session per run.
    var connector: MobileTransferManager.Connector {
        { [self] _ in try await self.connect() }
    }

    /// Closes every phone session (the app was killed or the session expired).
    func killSessions() async {
        for link in await sessions.drain() { await link.close() }
    }

    func shutdown() async {
        await killSessions()
        await host.stop()
        try? FileManager.default.removeItem(at: base)
    }

    func phoneFile(_ name: String, _ data: Data) throws -> URL {
        let url = phoneDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func bytes(_ count: Int, seed: UInt8 = 3) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 131) ^ Int(seed)) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

actor SessionBox {
    private var links: [LinkSession] = []
    func add(_ link: LinkSession) { links.append(link) }
    func drain() -> [LinkSession] {
        defer { links.removeAll() }
        return links
    }
}
