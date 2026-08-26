import Foundation
import CryptoKit
import os

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

    /// Fails CLOSED, like `sign`: an identity whose private key bytes do not
    /// parse must never quietly present an empty key (an empty key in a hello
    /// or grant is an admission-side landmine, not a local error). The key
    /// bytes are locally owned state, so failing to parse them is a
    /// programming or storage-corruption error, not an input error.
    public var publicKeyData: Data {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        else {
            preconditionFailure("PeerIdentity.privateKeyData is not a valid Curve25519 key")
        }
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

public final class InMemoryIdentityStore: IdentityStore, Sendable {
    private let deviceID: String
    /// The lock OWNS the mutable state, so sendability is checked by the
    /// compiler instead of promised by @unchecked.
    private let identities = OSAllocatedUnfairLock<[String: PeerIdentity]>(initialState: [:])

    /// One store instance models one device: every app identity it vends
    /// shares the same device ID (contract 1.5).
    public init(deviceID: String = "in-memory-device") {
        self.deviceID = deviceID
    }

    public func loadOrCreate(appIdentity: String) throws -> PeerIdentity {
        identities.withLock { identities in
            if let existing = identities[appIdentity] { return existing }
            let identity = PeerIdentity.generate(appIdentity: appIdentity, deviceID: deviceID)
            identities[appIdentity] = identity
            return identity
        }
    }
}
