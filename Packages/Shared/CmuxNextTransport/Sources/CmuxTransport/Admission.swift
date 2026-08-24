import Foundation
import CryptoKit

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
    public var issuedAt: Int64
    public var expiresAt: Int64?
    public var signature: Data

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

    /// Deterministic signing transcript. A fixed line format avoids every
    /// canonical-JSON trap; same style as the shipped device-registration flow.
    public static func transcript(
        accountID: String, deviceID: String, devicePublicKey: Data, appIdentity: String,
        grantID: String, issuedAt: Int64, expiresAt: Int64?
    ) -> Data {
        let lines = [
            "cmux/peer/grant/v1",
            accountID,
            deviceID,
            devicePublicKey.base64EncodedString(),
            appIdentity,
            grantID,
            String(issuedAt),
            expiresAt.map(String.init) ?? "-",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    public var transcriptData: Data {
        Self.transcript(
            accountID: accountID, deviceID: deviceID, devicePublicKey: devicePublicKey,
            appIdentity: appIdentity, grantID: grantID, issuedAt: issuedAt,
            expiresAt: expiresAt)
    }

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
    public let privateKeyData: Data

    public init() {
        privateKeyData = Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public init(privateKeyData: Data) {
        self.privateKeyData = privateKeyData
    }

    public var publicKeyData: Data {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        else { return Data() }
        return key.publicKey.rawRepresentation
    }

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
    case invalidSignature = "invalid-signature"
    case expired = "expired"
    case revoked = "revoked"
    /// Grant presented by a different network key than it was minted for.
    case keyMismatch = "key-mismatch"
    /// Grant presented by a different device ID than it was minted for.
    case deviceIDMismatch = "device-id-mismatch"
    /// e.g. cmux BETA presenting cmux INTERNAL's grant (contract 1.4).
    case appMismatch = "app-mismatch"
    case malformedHello = "malformed-hello"
    case protocolMismatch = "protocol-mismatch"
}

public enum AdmissionDecision: Sendable, Equatable {
    case admit
    case deny(DenialCode)
}

/// Offline admission: pinned server public key + local revocation set (9.3).
/// Order matters: nothing in the grant is trusted before its signature checks.
public struct GrantVerifier: Sendable {
    public let serverPublicKeyData: Data

    public init(serverPublicKeyData: Data) {
        self.serverPublicKeyData = serverPublicKeyData
    }

    public func decide(
        grant: PairingGrant, presentedByKey: Data, presentedByDeviceID: String,
        presentedByApp: String, revokedGrantIDs: Set<String>, now: Int64
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
        if revokedGrantIDs.contains(grant.grantID) {
            return .deny(.revoked)
        }
        if let expiresAt = grant.expiresAt, now >= expiresAt {
            return .deny(.expired)
        }
        return .admit
    }
}
