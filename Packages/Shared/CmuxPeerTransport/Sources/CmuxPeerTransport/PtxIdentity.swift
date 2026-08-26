import CryptoKit
import Foundation

/// One peer's durable identity: an Ed25519 key that seeds the iroh endpoint
/// secret, so the QUIC-authenticated remote key IS the peer identity, plus
/// the (device, app) pair that admission binds grants to.
public struct PtxIdentity: Sendable {
    public let deviceID: String
    public let appIdentity: String
    public let privateKeyData: Data
    public let publicKeyData: Data

    public init(deviceID: String, appIdentity: String, privateKeyData: Data) throws {
        self.deviceID = deviceID
        self.appIdentity = appIdentity
        self.privateKeyData = privateKeyData
        self.publicKeyData = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        ).publicKey.rawRepresentation
    }

    public static func generate(deviceID: String, appIdentity: String) -> PtxIdentity {
        let key = Curve25519.Signing.PrivateKey()
        // A freshly generated raw key always round-trips.
        return try! PtxIdentity(
            deviceID: deviceID, appIdentity: appIdentity,
            privateKeyData: key.rawRepresentation)
    }

    public var endpointIDHex: String {
        publicKeyData.map { String(format: "%02x", $0) }.joined()
    }

    public func sign(_ message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            .signature(for: message)
    }
}

/// Loads or creates a persisted identity. UserDefaults-backed: v2 identities
/// are per tagged dev build (the suite is the tagged bundle's defaults), and
/// losing one only forces a re-pair.
public enum PtxIdentityStore {
    public static func loadOrCreate(
        defaults: UserDefaults, key: String, deviceID: String, appIdentity: String
    ) -> PtxIdentity {
        if let stored = defaults.data(forKey: key),
            let identity = try? PtxIdentity(
                deviceID: deviceID, appIdentity: appIdentity, privateKeyData: stored)
        {
            return identity
        }
        let identity = PtxIdentity.generate(deviceID: deviceID, appIdentity: appIdentity)
        defaults.set(identity.privateKeyData, forKey: key)
        return identity
    }
}
