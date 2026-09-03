import Foundation
import CryptoKit

/// Errors raised when persisted identity key material cannot be parsed.
public enum PeerIdentityError: Error, Equatable, Sendable {
    case invalidPrivateKey
}

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
    private let publicKeyDataStorage: Data

    /// Creates an identity after validating its private key bytes.
    /// - Throws: ``PeerIdentityError/invalidPrivateKey`` when the bytes are
    ///   truncated or otherwise not a Curve25519 signing key.
    public init(
        appIdentity: String, deviceID: String, privateKeyData: Data
    ) throws {
        guard let key = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData) else {
            throw PeerIdentityError.invalidPrivateKey
        }
        self.appIdentity = appIdentity
        self.deviceID = deviceID
        self.privateKeyData = key.rawRepresentation
        self.publicKeyDataStorage = key.publicKey.rawRepresentation
    }

    private init(
        validatedAppIdentity: String, deviceID: String,
        privateKeyData: Data, publicKeyData: Data
    ) {
        self.appIdentity = validatedAppIdentity
        self.deviceID = deviceID
        self.privateKeyData = privateKeyData
        self.publicKeyDataStorage = publicKeyData
    }

    public static func generate(appIdentity: String, deviceID: String) -> PeerIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return PeerIdentity(
            validatedAppIdentity: appIdentity,
            deviceID: deviceID,
            privateKeyData: key.rawRepresentation,
            publicKeyData: key.publicKey.rawRepresentation)
    }

    /// Returns the validated public key corresponding to this identity.
    public var publicKeyData: Data { publicKeyDataStorage }

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
    func loadOrCreate(appIdentity: String) async throws -> PeerIdentity
}

public actor InMemoryIdentityStore: IdentityStore {
    private let deviceID: String
    private var identities: [String: PeerIdentity] = [:]

    /// One store instance models one device: every app identity it vends
    /// shares the same device ID (contract 1.5). A unique default prevents
    /// independent test stores from accidentally superseding one another.
    public init(deviceID: String = UUID().uuidString.lowercased()) {
        self.deviceID = deviceID
    }

    public func loadOrCreate(appIdentity: String) async throws -> PeerIdentity {
        if let existing = identities[appIdentity] { return existing }
        let identity = PeerIdentity.generate(appIdentity: appIdentity, deviceID: deviceID)
        identities[appIdentity] = identity
        return identity
    }
}
