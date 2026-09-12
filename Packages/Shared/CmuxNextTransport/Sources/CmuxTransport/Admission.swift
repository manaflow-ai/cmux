import Foundation
import CryptoKit

/// Errors raised when persisted grant-signer key material cannot be parsed.
public enum GrantSignerError: Error, Equatable, Sendable {
    /// Persisted signer bytes were not a valid Ed25519 private key.
    case invalidPrivateKey
}

/// Server-signed pairing grant (decision D8): the backend is the trust root.
/// Macs verify OFFLINE against a pinned server public key, so admission works
/// with the backend unreachable (contract 9.3, 9.5).
///
/// A grant binds four things (contract 3.5): the account, the durable device
/// ID (management identity: registry, supersession, revocation ergonomics),
/// the device's network KEY (enforcement identity: the only field the wire
/// can cryptographically prove), and the app identity. The key stays in the
/// grant because a grant is not a secret; without the key binding, a leaked
/// grant would admit anyone who replayed it.
public struct PairingGrant: Sendable, Equatable {
    /// Account identity authenticated by the grant signer.
    public var accountID: String
    /// Durable device ID (contract 1.5): ties the grant to the physical
    /// device across reinstalls and key regeneration.
    public var deviceID: String
    /// The device's Ed25519 network key (contract 1.1). Enforcement: must
    /// match the key the connection itself authenticates.
    public var devicePublicKey: Data
    /// Part of the identity, not metadata (contract 1.4).
    public var appIdentity: String
    /// Revocation handle: revocations arrive as grant IDs (9.3, 9.6).
    public var grantID: String
    /// Issue time in Unix seconds, covered by the signature.
    public var issuedAt: Int64
    /// Expiry in Unix seconds, or nil for a non-expiring grant.
    public var expiresAt: Int64?
    /// Detached Ed25519 signature over ``transcriptData``.
    public var signature: Data

    /// Assembles grant fields without verifying their signature or admission policy.
    /// - Parameters:
    ///   - accountID: Account authorized by the signer.
    ///   - deviceID: Durable device identity authorized by the signer.
    ///   - devicePublicKey: Network key required to present this grant.
    ///   - appIdentity: App identity authorized by the signer.
    ///   - grantID: Unique revocation handle.
    ///   - issuedAt: Issue time in Unix seconds.
    ///   - expiresAt: Optional expiry in Unix seconds.
    ///   - signature: Signature authenticating these fields.
    public init(
        accountID: String, deviceID: String, devicePublicKey: Data, appIdentity: String,
        grantID: String, issuedAt: Int64, expiresAt: Int64?, signature: Data
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.appIdentity = appIdentity
        self.grantID = grantID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// Deterministic signing transcript, domain-separated and length-prefixed
    /// so it is INJECTIVE: no two distinct field tuples can produce the same
    /// bytes. (v1 newline-joined free-form fields, so a "\n" inside one field
    /// shifted the boundaries — ("a\nb", "c") signed identically to
    /// ("a", "b\nc"). The prefix bump to v2 invalidates every v1 signature;
    /// grants are dev-only so far, so nothing shipped is orphaned.)
    /// - Parameters:
    ///   - accountID: Account to bind into the signature.
    ///   - deviceID: Durable device identifier to bind.
    ///   - devicePublicKey: Exact network public-key bytes to bind.
    ///   - appIdentity: App identity to bind.
    ///   - grantID: Unique revocation handle to bind.
    ///   - issuedAt: Issue time in Unix seconds.
    ///   - expiresAt: Optional expiry in Unix seconds.
    /// - Returns: Canonical v2 transcript; every field must fit in a UInt32 byte length.
    public static func transcript(
        accountID: String, deviceID: String, devicePublicKey: Data, appIdentity: String,
        grantID: String, issuedAt: Int64, expiresAt: Int64?
    ) -> Data {
        let fields: [Data] = [
            Data(accountID.utf8),
            Data(deviceID.utf8),
            devicePublicKey,
            Data(appIdentity.utf8),
            Data(grantID.utf8),
            Data(String(issuedAt).utf8),
            Data((expiresAt.map(String.init) ?? "-").utf8),
        ]
        var transcript = Data("cmux/peer/grant/v2".utf8)
        for field in fields {
            let length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: length) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        return transcript
    }

    /// Domain-separated transcript a phone signs when requesting a bootstrap
    /// grant over an already-authorized legacy channel. The proof binds all
    /// caller-controlled identity fields, so the host cannot be tricked into
    /// minting a grant for a different key than the requester owns.
    /// - Parameters:
    ///   - deviceID: Claimed durable device identifier.
    ///   - devicePublicKey: Claimed signing public key.
    ///   - appIdentity: Claimed app identity.
    /// - Returns: Pair-request transcript; every field must fit in a UInt32 byte length.
    public static func requestProofTranscript(
        deviceID: String, devicePublicKey: Data, appIdentity: String
    ) -> Data {
        let fields = [
            Data(deviceID.utf8), devicePublicKey, Data(appIdentity.utf8)
        ]
        var transcript = Data("cmux/peer/pair-request/v1".utf8)
        for field in fields {
            let length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: length) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        return transcript
    }

    /// Canonical bytes authenticated by this grant's detached signature.
    public var transcriptData: Data {
        Self.transcript(
            accountID: accountID, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, grantID: grantID, issuedAt: issuedAt,
            expiresAt: expiresAt)
    }

    /// Wire JSON representation, with binary fields base64-encoded and absent expiry omitted.
    public var payloadValue: JSONValue {
        var object: [String: JSONValue] = [
            "account": .string(accountID),
            "deviceId": .string(deviceID),
            "key": .data(devicePublicKey),
            "app": .string(appIdentity),
            "id": .string(grantID),
            "iat": .int(issuedAt),
            "sig": .data(signature),
        ]
        if let expiresAt { object["exp"] = .int(expiresAt) }
        return .object(object)
    }

    /// Parses required wire fields without verifying signature or admission policy.
    /// - Parameter payloadValue: Grant object; nil or malformed required fields fail parsing.
    ///
    /// Use ``GrantVerifier`` before trusting the result. An absent or noninteger
    /// optional expiry is represented as nil by this structural parser.
    public init?(payloadValue: JSONValue?) {
        guard let object = payloadValue?.objectValue,
            let accountID = object["account"]?.stringValue,
            let deviceID = object["deviceId"]?.stringValue,
            let devicePublicKey = object["key"]?.dataValue,
            let appIdentity = object["app"]?.stringValue,
            let grantID = object["id"]?.stringValue,
            let issuedAt = object["iat"]?.intValue,
            let signature = object["sig"]?.dataValue
        else { return nil }
        self.init(
            accountID: accountID, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, grantID: grantID, issuedAt: issuedAt,
            expiresAt: object["exp"]?.intValue, signature: signature)
    }
}

/// Mints grants. In production this is the backend's job (D8); in the harness
/// it is the fake backend used by the loopback host and later by hostd.
public struct GrantSigner: Sendable {
    /// Raw signer secret; persist securely and never share it with admitted peers.
    public let privateKeyData: Data
    private let publicKeyDataStorage: Data

    /// Generates a fresh signer without persisting its key.
    public init() {
        let key = Curve25519.Signing.PrivateKey()
        privateKeyData = key.rawRepresentation
        publicKeyDataStorage = key.publicKey.rawRepresentation
    }

    /// Creates a signer after validating persisted private-key bytes.
    /// - Parameter privateKeyData: Existing raw Ed25519 signing key.
    /// - Throws: ``GrantSignerError/invalidPrivateKey`` when the bytes are not
    ///   a valid Curve25519 signing key.
    public init(privateKeyData: Data) throws {
        guard let key = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData) else {
            throw GrantSignerError.invalidPrivateKey
        }
        self.privateKeyData = key.rawRepresentation
        self.publicKeyDataStorage = key.publicKey.rawRepresentation
    }

    /// Returns the validated public key corresponding to this signer.
    public var publicKeyData: Data { publicKeyDataStorage }

    /// Signs an explicit grant; authorization to issue it remains the caller's responsibility.
    ///
    /// - Parameters:
    ///   - accountID: Account to authorize.
    ///   - deviceID: Durable device to authorize.
    ///   - devicePublicKey: Network key required when presenting the grant.
    ///   - appIdentity: App identity to authorize.
    ///   - grantID: Unique revocation handle.
    ///   - issuedAt: Issue time in Unix seconds.
    ///   - expiresAt: Optional Unix expiry; defaults to a non-expiring grant for harnesses.
    /// - Returns: Signed grant, ready for offline verification with this signer's public key.
    /// - Throws: A cryptographic key or signing error.
    public func mint(
        accountID: String, deviceID: String, devicePublicKey: Data, appIdentity: String,
        grantID: String, issuedAt: Int64, expiresAt: Int64? = nil
    ) throws -> PairingGrant {
        let transcript = PairingGrant.transcript(
            accountID: accountID, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, grantID: grantID, issuedAt: issuedAt,
            expiresAt: expiresAt)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return PairingGrant(
            accountID: accountID, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, grantID: grantID, issuedAt: issuedAt,
            expiresAt: expiresAt, signature: try key.signature(for: transcript))
    }
}

/// Machine-readable denial codes the phone surfaces verbatim (contract 3.2).
public enum DenialCode: String, Sendable, Equatable, CaseIterable {
    /// The pinned signer key did not authenticate the grant transcript.
    case invalidSignature = "invalid-signature"
    /// The grant's expiry was reached.
    case expired = "expired"
    /// The grant's revocation handle is present in the host denylist.
    case revoked = "revoked"
    /// Grant presented by a different network key than it was minted for.
    case keyMismatch = "key-mismatch"
    /// Grant presented by a different device ID than it was minted for.
    case deviceIDMismatch = "device-id-mismatch"
    /// e.g. cmux BETA presenting cmux INTERNAL's grant (contract 1.4).
    case appMismatch = "app-mismatch"
    /// Grant belongs to a different signed-in account than the host currently
    /// serving this connection. Account binding is checked only when the host
    /// supplies an expected account identity.
    case accountMismatch = "account-mismatch"
    /// Required hello or grant fields were missing or malformed.
    case malformedHello = "malformed-hello"
    /// The peer did not request the supported protocol identifier.
    case protocolMismatch = "protocol-mismatch"
}

/// Offline admission verdict with a stable, typed denial reason.
public enum AdmissionDecision: Sendable, Equatable {
    /// Every configured signature, identity, revocation, and expiry check passed.
    case admit
    /// The first failing admission check, in verification order.
    case deny(DenialCode)
}

/// Offline admission: pinned server public key + local revocation set (9.3).
/// Order matters: nothing in the grant is trusted before its signature checks.
public struct GrantVerifier: Sendable {
    /// Pinned grant-signing public key, independent of the connecting device key.
    public let serverPublicKeyData: Data

    /// Creates an offline verifier without loading keys or consulting the network.
    /// - Parameter serverPublicKeyData: Raw Ed25519 trust-root public key.
    public init(serverPublicKeyData: Data) {
        self.serverPublicKeyData = serverPublicKeyData
    }

    /// Verifies signature first, then peer binding, account policy, revocation, and expiry.
    ///
    /// - Parameters:
    ///   - grant: Untrusted grant presented by the peer.
    ///   - presentedByKey: Network key authenticated by the substrate when available.
    ///   - presentedByDeviceID: Device identifier claimed in the hello.
    ///   - presentedByApp: App identity claimed in the hello.
    ///   - revokedGrantIDs: Authoritative local set of revoked grant handles.
    ///   - now: Current time in Unix seconds.
    ///   - expectedAccountID: Required host account; nil omits that check, empty denies.
    /// - Returns: Admission or the first stable denial reason; invalid inputs fail closed.
    public func decide(
        grant: PairingGrant, presentedByKey: Data, presentedByDeviceID: String,
        presentedByApp: String, revokedGrantIDs: Set<String>, now: Int64,
        expectedAccountID: String? = nil
    ) -> AdmissionDecision {
        guard
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: serverPublicKeyData),
            key.isValidSignature(grant.signature, for: grant.transcriptData)
        else {
            return .deny(.invalidSignature)
        }
        guard grant.devicePublicKey == presentedByKey else {
            return .deny(.keyMismatch)
        }
        guard grant.deviceID == presentedByDeviceID else {
            return .deny(.deviceIDMismatch)
        }
        guard grant.appIdentity == presentedByApp else {
            return .deny(.appMismatch)
        }
        if let expectedAccountID,
            (expectedAccountID.isEmpty || grant.accountID != expectedAccountID)
        {
            return .deny(.accountMismatch)
        }
        if revokedGrantIDs.contains(grant.grantID) {
            return .deny(.revoked)
        }
        if let expiresAt = grant.expiresAt, now >= expiresAt {
            return .deny(.expired)
        }
        return .admit
    }
}
