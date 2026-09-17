import Foundation
import os
@testable import CmuxMobileCloud

/// Scripted control plane.
final class FakeCloudVMService: CloudVMServing, @unchecked Sendable {
    struct Calls: Sendable {
        var list = 0
        var enroll: [(publicKey: String, fingerprint: String, deviceName: String?)] = []
        var attach: [(machineID: String, fingerprint: String)] = []
        var approve: [(machineID: String, invitationId: String)] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: Calls())
    var calls: Calls { lock.withLock { $0 } }

    var machines: Result<[CloudMachine], any Error> = .success([])
    var enrollment: Result<CloudTunnelEnrollment, any Error> = .success(Fixtures.enrollment)
    var attach: Result<CloudAttachEndpoint, any Error> = .success(CloudAttachEndpoint(route: "ws://[fd00::10]:1337/v1/link", session: "s1"))
    var approvals: [Bool] = [true]

    func listMachines() async throws -> [CloudMachine] {
        lock.withLock { $0.list += 1 }
        return try machines.get()
    }

    func enrollTunnel(clientPublicKey: String, deviceFingerprint: String, deviceName: String?) async throws -> CloudTunnelEnrollment {
        lock.withLock { $0.enroll.append((clientPublicKey, deviceFingerprint, deviceName)) }
        return try enrollment.get()
    }

    func openAttach(machineID: String, deviceFingerprint: String) async throws -> CloudAttachEndpoint {
        lock.withLock { $0.attach.append((machineID, deviceFingerprint)) }
        return try attach.get()
    }

    func approveEnrollment(machineID: String, invitationId: String) async throws -> Bool {
        let index = lock.withLock { calls -> Int in
            calls.approve.append((machineID, invitationId))
            return calls.approve.count - 1
        }
        return index < approvals.count ? approvals[index] : approvals.last ?? true
    }
}

final class FakeTunnel: CloudTunnel {
    let config: String
    init(config: String) { self.config = config }
}

final class FakeTunnelStarter: CloudTunnelStarting, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    var startedConfigs: [String] { lock.withLock { $0 } }
    var failure: (any Error)?

    func start(wgQuickConfig: String) async throws -> any CloudTunnel {
        lock.withLock { $0.append(wgQuickConfig) }
        if let failure { throw failure }
        return FakeTunnel(config: wgQuickConfig)
    }
}

struct StubError: Error, Equatable { let message: String }

final class FakeTerminalSession: CloudTerminalSession, @unchecked Sendable {
    struct State {
        var attached: String?
        var sent: [Data] = []
        var resizes: [(Int, Int)] = []
        var detached = 0
        var disconnected = 0
        var created: [String?] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    var state: State { lock.withLock { $0 } }
    var terminals: [CloudTerminalSummary] = [CloudTerminalSummary(id: "t1", name: "shell")]
    var outputHandler: (@Sendable (CloudTerminalOutputEvent) -> Void)? {
        lock.withLock { _ in handlerBox.withLock { $0 } }
    }
    private let handlerBox = OSAllocatedUnfairLock<(@Sendable (CloudTerminalOutputEvent) -> Void)?>(initialState: nil)

    func listTerminals() async throws -> [CloudTerminalSummary] { terminals }

    func createTerminal(name: String?) async throws -> String {
        lock.withLock { $0.created.append(name) }
        let id = "t\(terminals.count + 1)"
        terminals.append(CloudTerminalSummary(id: id, name: name))
        return id
    }

    func attach(terminalID: String, output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void) async throws {
        lock.withLock { $0.attached = terminalID }
        handlerBox.withLock { $0 = output }
    }

    func detach() { lock.withLock { $0.detached += 1 } }
    func send(_ bytes: Data) { lock.withLock { $0.sent.append(bytes) } }
    func resize(cols: Int, rows: Int) { lock.withLock { $0.resizes.append((cols, rows)) } }
    func disconnect() { lock.withLock { $0.disconnected += 1 } }
}

final class FakeConnector: CloudTerminalConnecting, @unchecked Sendable {
    struct Connect: Sendable {
        var route: String
        var stateDirectory: URL
        var deviceName: String
        var invitation: String?
        var hasTunnel: Bool
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Connect]())
    var connects: [Connect] { lock.withLock { $0 } }
    let session = FakeTerminalSession()
    var failure: (any Error)?

    func connect(route: String, stateDirectory: URL, deviceName: String, invitation: String?, tunnel: (any CloudTunnel)?) async throws -> any CloudTerminalSession {
        lock.withLock {
            $0.append(Connect(route: route, stateDirectory: stateDirectory, deviceName: deviceName, invitation: invitation, hasTunnel: tunnel != nil))
        }
        if let failure { throw failure }
        return session
    }
}

enum Fixtures {
    static let serverConfig = """
    [Interface]
    PrivateKey =
    Address = 100.64.0.7/32
    Address = fd7a:7570:6c6b::7/128
    MTU = 1200

    [Peer]
    PublicKey = c2VydmVyLXB1YmxpYy1rZXktYmFzZTY0LXBsYWNlaG9sZGVyPT0=
    AllowedIPs = 10.0.0.0/8, fd00::/8
    Endpoint = [2600:1f18::1]:51820
    """

    static let enrollment = CloudTunnelEnrollment(
        tunnelId: "tun_1",
        provider: "freestyle",
        deviceFingerprint: "ios-abc",
        clientConfig: serverConfig,
        serverPublicKey: "c2VydmVyLXB1YmxpYy1rZXktYmFzZTY0LXBsYWNlaG9sZGVyPT0=",
        endpointHost: "2600:1f18::1",
        endpointPort: 51820,
        routes: ["10.0.0.0/8", "fd00::/8"],
        addressV4: "100.64.0.7",
        addressV6: "fd7a:7570:6c6b::7",
        created: true,
        rotated: false
    )

    static let enrollmentJSON = """
    {"tunnelId":"tun_1","provider":"freestyle","deviceFingerprint":"ios-abc",
     "clientConfig":"[Interface]\\nPrivateKey =\\nAddress = 100.64.0.7/32\\nMTU = 1200\\n\\n[Peer]\\nPublicKey = spk\\nAllowedIPs = 10.0.0.0/8, fd00::/8\\nEndpoint = [2600:1f18::1]:51820\\n",
     "clientPublicKey":"cpk","serverPublicKey":"spk","endpointHost":"2600:1f18::1","endpointPort":51820,
     "routes":["10.0.0.0/8","fd00::/8"],"address":{"ipv4":"100.64.0.7","ipv6":"fd7a:7570:6c6b::7"},
     "network":{"cidr":"10.100.0.0/16","cidrV6":"fd7a:7570:6c6b::/64"},"created":true,"rotated":false}
    """

    static func stateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cloud-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
