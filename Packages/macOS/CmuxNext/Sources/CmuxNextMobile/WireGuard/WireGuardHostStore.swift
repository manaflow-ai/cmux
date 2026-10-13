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
    /// Addresses of unpaired phones, oldest first; reused last.
    var retiredAddresses: [String]?

    static func fresh() -> WireGuardHostState {
        WireGuardHostState(hostID: UUID().uuidString.lowercased(), privateKey: WireGuardKey(), listenPort: nil, phones: [],
                           retiredAddresses: [])
    }
}

struct WireGuardHostStore: Sendable {
    let file: URL

    init(stateDirectory: URL) {
        file = stateDirectory.appendingPathComponent("cmux-wireguard", isDirectory: true)
            .appendingPathComponent("host.json")
    }

    /// The saved state, or a new identity when there is none yet. Any other
    /// read or decode failure throws: replacing the file would lose the
    /// host key and every pairing.
    func load() throws -> WireGuardHostState {
        guard FileManager.default.fileExists(atPath: file.path) else {
            let state = WireGuardHostState.fresh()
            try save(state)
            return state
        }
        return try JSONDecoder().decode(WireGuardHostState.self, from: Data(contentsOf: file))
    }

    func save(_ state: WireGuardHostState) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Owner-only from creation: the file holds the host's private key.
        let temporary = directory.appendingPathComponent(".host.json.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(state),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
