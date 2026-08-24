import Foundation
import CryptoKit

/// A peer identity: one Ed25519 keypair scoped to (device, app identity), plus
/// the durable device ID. cmux BETA, cmux INTERNAL, and cmux-lite on the same
/// phone are three fully separate peers (contract 1.4) that share one device ID
/// (contract 1.5). The public key IS the network address.
public struct PeerIdentity: Sendable, Equatable {
    /// The app identity component, e.g. a bundle identifier. Part of who this
    /// peer is, not metadata.
    public let appIdentity: String
    /// Durable device ID (contract 1.5, Aziz redline 08-19): platform-provided
    /// where the platform has one (macOS hardware UUID), else generated once at
    /// first install + launch and persisted across installs and relaunches
    /// (Keychain-backed on device). Identifies the physical device for the
    /// registry, supersession, and revocation ergonomics. It is NOT an
    /// admission credential by itself: it is self-reported, so enforcement
    /// stays with the key the wire authenticates.
    public let deviceID: String
    public let privateKeyData: Data

    public init(appIdentity: String, deviceID: String, privateKeyData: Data) {
        self.appIdentity = appIdentity
        self.deviceID = deviceID
        self.privateKeyData = privateKeyData
    }

    public static func generate(appIdentity: String, deviceID: String) -> PeerIdentity {
        PeerIdentity(
            appIdentity: appIdentity,
            deviceID: deviceID,
            privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    public var publicKeyData: Data {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        else { return Data() }
        return key.publicKey.rawRepresentation
    }

    public func sign(_ message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            .signature(for: message)
    }
}

/// Where identities live. P0 ships in-memory; the Keychain-backed store must be
/// byte-compatible with shipped builds (contract 1.2, 1.3), persist the device
/// ID across installs (1.5), and lands in the on-device phase, where it can
/// actually be tested against a real Keychain.
public protocol IdentityStore: Sendable {
    func loadOrCreate(appIdentity: String) throws -> PeerIdentity
}

public final class InMemoryIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private let deviceID: String
    private var identities: [String: PeerIdentity] = [:]

    /// One store instance models one device: every app identity it vends
    /// shares the same device ID (contract 1.5).
    public init(deviceID: String = "in-memory-device") {
        self.deviceID = deviceID
    }

    public func loadOrCreate(appIdentity: String) throws -> PeerIdentity {
        lock.withLock {
            if let existing = identities[appIdentity] { return existing }
            let identity = PeerIdentity.generate(appIdentity: appIdentity, deviceID: deviceID)
            identities[appIdentity] = identity
            return identity
        }
    }
}
