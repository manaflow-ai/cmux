import CryptoKit
public import Foundation

/// The device's irx network identity: one long-lived Ed25519 keypair whose
/// public key IS the iroh EndpointId, plus the durable identifiers the broker
/// binds it to. The same seed feeds the iroh endpoint's secret key, so the
/// key the remote side authenticates during the QUIC handshake equals
/// `publicKeyData`.
public struct IrxIdentity: Sendable, Equatable {
    /// 32-byte Ed25519 seed.
    public let privateKeyData: Data
    /// Durable device ID (shared with the rest of the app, injected).
    public let deviceID: String
    /// Rotates only when the identity is regenerated.
    public let appInstanceID: String

    public init(privateKeyData: Data, deviceID: String, appInstanceID: String) {
        self.privateKeyData = privateKeyData
        self.deviceID = deviceID
        self.appInstanceID = appInstanceID
    }

    public var publicKeyData: Data {
        guard
            let key = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyData)
        else { return Data() }
        return key.publicKey.rawRepresentation
    }

    /// Lowercased hex EndpointId, the broker's `endpointId` field.
    public var endpointIDHex: String {
        publicKeyData.map { String(format: "%02x", $0) }.joined()
    }

    public func sign(_ message: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return try key.signature(for: message)
    }
}

/// Identity persistence seam. The DEBUG runtime uses the file store below;
/// a Keychain-backed store slots in here for release adoption.
public protocol IrxIdentityStoring: Sendable {
    func load() throws -> IrxIdentity?
    func save(_ identity: IrxIdentity) throws
}

public struct IrxFileIdentityStore: IrxIdentityStoring {
    private struct Snapshot: Codable {
        var privateKey: Data
        var deviceID: String
        var appInstanceID: String
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> IrxIdentity? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        return IrxIdentity(
            privateKeyData: snapshot.privateKey,
            deviceID: snapshot.deviceID,
            appInstanceID: snapshot.appInstanceID
        )
    }

    public func save(_ identity: IrxIdentity) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = Snapshot(
            privateKey: identity.privateKeyData,
            deviceID: identity.deviceID,
            appInstanceID: identity.appInstanceID
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum IrxIdentityProvisioner {
    /// Loads the persisted identity or mints one. The device ID is pinned by
    /// the caller: if a stored identity carries a different device ID (e.g.
    /// the app's durable ID was reset), the identity is regenerated so the
    /// broker binding and the grant tuples can never disagree.
    public static func loadOrCreate(
        store: some IrxIdentityStoring,
        deviceID: String
    ) throws -> IrxIdentity {
        if let existing = try store.load(), existing.deviceID == deviceID,
            !existing.privateKeyData.isEmpty
        {
            return existing
        }
        let identity = IrxIdentity(
            privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation,
            deviceID: deviceID,
            appInstanceID: UUID().uuidString.lowercased()
        )
        try store.save(identity)
        return identity
    }
}
