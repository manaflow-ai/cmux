import CryptoKit
import Foundation

/// Why a hello was refused. Terminal for auto-retry: a denial means the
/// stored credentials are stale, and redialing with the same ones can only
/// fail the same way. The code travels in the QUIC close reason.
public enum PtxDenial: String, Sendable, CaseIterable {
    case invalidSignature = "denied-invalid-signature"
    case grantExpired = "denied-grant-expired"
    case keyMismatch = "denied-key-mismatch"
    case deviceMismatch = "denied-device-mismatch"
    case appMismatch = "denied-app-mismatch"
    case revoked = "denied-revoked"
    case malformedHello = "denied-malformed-hello"
    case protocolMismatch = "denied-protocol-mismatch"
}

/// Attributed close reasons. Every deliberate close names one; the soak
/// classifies any session end without one as a failure.
public enum PtxCloseReason: String, Sendable, CaseIterable {
    case superseded = "superseded"
    case userRequested = "user-requested"
    case hostStopping = "host-stopping"
    case explicitRedial = "explicit-redial"
    case admissionTimeout = "admission-timeout"
}

/// A Mac-signed pairing grant: the Mac's persisted signer key is the
/// admission authority for that Mac. Bound to the phone's endpoint key, so a
/// leaked grant is useless without the phone's private key.
public struct PtxGrant: Sendable, Equatable, Codable {
    public var grantID: String
    public var account: String
    public var deviceID: String
    public var devicePublicKey: Data
    public var appIdentity: String
    public var issuedAt: Int64
    public var expiresAt: Int64
    public var signature: Data

    public init(
        grantID: String, account: String, deviceID: String, devicePublicKey: Data,
        appIdentity: String, issuedAt: Int64, expiresAt: Int64, signature: Data
    ) {
        self.grantID = grantID
        self.account = account
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.appIdentity = appIdentity
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// Fixed line-format transcript; both sides must produce identical bytes.
    static func transcript(
        grantID: String, account: String, deviceID: String, devicePublicKey: Data,
        appIdentity: String, issuedAt: Int64, expiresAt: Int64
    ) -> Data {
        let keyHex = devicePublicKey.map { String(format: "%02x", $0) }.joined()
        return Data(
            """
            cmux/ptx/grant/1
            \(grantID)
            \(account)
            \(deviceID)
            \(keyHex)
            \(appIdentity)
            \(issuedAt)
            \(expiresAt)
            """.utf8)
    }

    var transcript: Data {
        Self.transcript(
            grantID: grantID, account: account, deviceID: deviceID,
            devicePublicKey: devicePublicKey, appIdentity: appIdentity,
            issuedAt: issuedAt, expiresAt: expiresAt)
    }

    public var payloadValue: PtxJSON {
        .object([
            "grant_id": .string(grantID),
            "account": .string(account),
            "device_id": .string(deviceID),
            "device_public_key": .data(devicePublicKey),
            "app_identity": .string(appIdentity),
            "iat": .int(issuedAt),
            "exp": .int(expiresAt),
            "signature": .data(signature),
        ])
    }

    public init?(payload: PtxJSON) {
        guard let object = payload.objectValue,
            let grantID = object["grant_id"]?.stringValue,
            let account = object["account"]?.stringValue,
            let deviceID = object["device_id"]?.stringValue,
            let devicePublicKey = object["device_public_key"]?.dataValue,
            let appIdentity = object["app_identity"]?.stringValue,
            let issuedAt = object["iat"]?.intValue,
            let expiresAt = object["exp"]?.intValue,
            let signature = object["signature"]?.dataValue
        else { return nil }
        self.init(
            grantID: grantID, account: account, deviceID: deviceID,
            devicePublicKey: devicePublicKey, appIdentity: appIdentity,
            issuedAt: issuedAt, expiresAt: expiresAt, signature: signature)
    }
}

/// The Mac-side grant authority. The signing key MUST be persisted: a fresh
/// signer invalidates every phone's stored grant (a known legacy-field trap).
public struct PtxGrantSigner: Sendable {
    public let privateKeyData: Data
    public let publicKeyData: Data

    public init(privateKeyData: Data) throws {
        self.privateKeyData = privateKeyData
        self.publicKeyData = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        ).publicKey.rawRepresentation
    }

    public static func loadOrCreate(defaults: UserDefaults, key: String) -> PtxGrantSigner {
        if let stored = defaults.data(forKey: key),
            let signer = try? PtxGrantSigner(privateKeyData: stored)
        {
            return signer
        }
        let fresh = Curve25519.Signing.PrivateKey()
        defaults.set(fresh.rawRepresentation, forKey: key)
        return try! PtxGrantSigner(privateKeyData: fresh.rawRepresentation)
    }

    public func mint(
        account: String, deviceID: String, devicePublicKey: Data, appIdentity: String,
        lifetime: TimeInterval, now: Date = Date()
    ) throws -> PtxGrant {
        let issuedAt = Int64(now.timeIntervalSince1970)
        let expiresAt = Int64(now.addingTimeInterval(lifetime).timeIntervalSince1970)
        let grantID = UUID().uuidString.lowercased()
        let transcript = PtxGrant.transcript(
            grantID: grantID, account: account, deviceID: deviceID,
            devicePublicKey: devicePublicKey, appIdentity: appIdentity,
            issuedAt: issuedAt, expiresAt: expiresAt)
        let signature = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        ).signature(for: transcript)
        return PtxGrant(
            grantID: grantID, account: account, deviceID: deviceID,
            devicePublicKey: devicePublicKey, appIdentity: appIdentity,
            issuedAt: issuedAt, expiresAt: expiresAt, signature: signature)
    }
}

public struct PtxGrantVerifier: Sendable {
    public var trustedSignerKey: Data
    public var revokedGrantIDs: Set<String>

    public init(trustedSignerKey: Data, revokedGrantIDs: Set<String> = []) {
        self.trustedSignerKey = trustedSignerKey
        self.revokedGrantIDs = revokedGrantIDs
    }

    /// Signature first: nothing else in the grant can be trusted before it.
    /// `remoteKey` is the QUIC-authenticated key of the peer that sent it.
    public func decide(
        grant: PtxGrant, remoteKey: Data, helloDeviceID: String, helloApp: String,
        now: Date = Date()
    ) -> PtxDenial? {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trustedSignerKey),
            key.isValidSignature(grant.signature, for: grant.transcript)
        else { return .invalidSignature }
        guard grant.devicePublicKey == remoteKey else { return .keyMismatch }
        guard grant.deviceID == helloDeviceID else { return .deviceMismatch }
        guard grant.appIdentity == helloApp else { return .appMismatch }
        guard !revokedGrantIDs.contains(grant.grantID) else { return .revoked }
        guard Int64(now.timeIntervalSince1970) < grant.expiresAt else { return .grantExpired }
        return nil
    }
}

/// Everything a phone needs to dial a Mac: endpoint identity, relay home,
/// direct addresses, and the signer key its grants verify against (pinned at
/// pair time, so a MITM broker can't swap admission authority later).
public struct PtxTicket: Sendable, Equatable, Codable {
    public var hostEndpointKey: Data
    public var hostSignerKey: Data
    public var hostDeviceID: String
    public var relayURL: String?
    public var directAddresses: [String]

    public init(
        hostEndpointKey: Data, hostSignerKey: Data, hostDeviceID: String,
        relayURL: String?, directAddresses: [String]
    ) {
        self.hostEndpointKey = hostEndpointKey
        self.hostSignerKey = hostSignerKey
        self.hostDeviceID = hostDeviceID
        self.relayURL = relayURL
        self.directAddresses = directAddresses
    }

    public func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    public init(encoded: String) throws {
        guard let data = Data(base64Encoded: encoded) else {
            throw PtxFrameError.malformedJSON
        }
        self = try JSONDecoder().decode(PtxTicket.self, from: data)
    }
}
