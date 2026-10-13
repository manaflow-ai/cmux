public import CmuxWireGuardPairing
public import Foundation

/// A phone paired with this Mac over WireGuard.
public struct WireGuardPairedPhone: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    public var publicKey: WireGuardKey
    public var presharedKey: WireGuardKey
    /// The phone's tunnel address (10.77.0.x).
    public var address: String
    public var pairedAt: Date

    public init(id: String, name: String, model: String, publicKey: WireGuardKey, presharedKey: WireGuardKey,
                address: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.model = model
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.address = address
        self.pairedAt = pairedAt
    }
}

/// The host's durable state: its WireGuard key, id, UDP port and paired
/// phones. One JSON file, owner-only, in the app's namespaced state
/// directory, so each tagged build has its own host identity.
struct WireGuardHostState: Codable, Sendable {
    var hostID: String
    var privateKey: WireGuardKey
    var listenPort: UInt16?
    var phones: [WireGuardPairedPhone]

    static func fresh() -> WireGuardHostState {
        WireGuardHostState(hostID: UUID().uuidString.lowercased(), privateKey: WireGuardKey(), listenPort: nil, phones: [])
    }
}

struct WireGuardHostStore: Sendable {
    let file: URL

    init(stateDirectory: URL) {
        file = stateDirectory.appendingPathComponent("cmux-wireguard", isDirectory: true)
            .appendingPathComponent("host.json")
    }

    func load() throws -> WireGuardHostState {
        guard let data = try? Data(contentsOf: file) else {
            let state = WireGuardHostState.fresh()
            try save(state)
            return state
        }
        return try JSONDecoder().decode(WireGuardHostState.self, from: data)
    }

    func save(_ state: WireGuardHostState) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
