import CryptoKit
import Foundation

/// The install that registers a presence key: its owner ids, the backend
/// environment name, a fresh install token, and the install key's signer.
public struct PresenceKeyInstall: Sendable {
    public var user: String
    public var install: String
    /// The backend's ENVIRONMENT: staging, production or development.
    public var environment: String
    public var token: @Sendable () async throws -> String
    /// ES256 with the install key (not the presence key), raw r||s or DER.
    public var sign: @Sendable (Data) async throws -> Data

    public init(user: String, install: String, environment: String,
                token: @escaping @Sendable () async throws -> String,
                sign: @escaping @Sendable (Data) async throws -> Data) {
        self.user = user
        self.install = install
        self.environment = environment
        self.token = token
        self.sign = sign
    }
}

/// App Attest key generation and attestation (iOS). Nil on macOS.
public protocol AppAttestKeyAttester: Sendable {
    /// A new App Attest key; returns its key id.
    func generateKey() async throws -> String
    /// The attestation object (CBOR) for `keyID` over `clientDataHash`.
    func attest(keyID: String, clientDataHash: Data) async throws -> Data
}

/// POST with a bearer token. Transport failures throw.
public protocol PresenceKeyTransport: Sendable {
    func post(_ path: String, json: Data, bearer: String) async throws -> (status: Int, body: Data)
}

/// A registered presence key. `appAttestKeyID` is the key whose assertions
/// later go with lowering proofs (iOS only).
public struct PresenceKeyRegistered: Hashable, Sendable {
    public var thumbprint: String
    public var appAttestKeyID: String?
}

/// `POST /v1/presence-key` (home-messaging.md section 21): an owner device
/// registers its presence key. The install key signs
/// `cmux-presence-key-v1\n<environment>\n<user>\n<install>\n<thumbprint>`;
/// on iOS an App Attest attestation whose client data is the thumbprint
/// (clientDataHash = SHA-256 of its UTF-8 bytes) goes with it.
public struct PresenceKeyRegistration: Sendable {
    public static let path = "/v1/presence-key"
    public static let domain = "cmux-presence-key-v1"

    let transport: any PresenceKeyTransport
    let attester: (any AppAttestKeyAttester)?

    /// - Parameter attester: required on iOS (the owner refuses an iOS
    ///   registration without an attestation); nil on macOS.
    public init(transport: any PresenceKeyTransport, attester: (any AppAttestKeyAttester)?) {
        self.transport = transport
        self.attester = attester
    }

    /// The public JWK of an uncompressed P-256 point (X9.63, 65 bytes).
    public static func jwk(x963: Data) throws -> [String: String] {
        guard x963.count == 65, x963.first == 0x04 else { throw PresenceKeyError.invalidPublicKey }
        return ["kty": "EC", "crv": "P-256",
                "x": x963.subdata(in: 1..<33).textConfirmBase64URL,
                "y": x963.subdata(in: 33..<65).textConfirmBase64URL]
    }

    /// RFC 7638 thumbprint: SHA-256 of the required members in lexical order,
    /// base64url.
    public static func thumbprint(x963: Data) throws -> String {
        let jwk = try jwk(x963: x963)
        let canonical = #"{"crv":"P-256","kty":"EC","x":"\#(jwk["x"]!)","y":"\#(jwk["y"]!)"}"#
        return Data(SHA256.hash(data: Data(canonical.utf8))).textConfirmBase64URL
    }

    /// The exact bytes the install key signs.
    public static func message(environment: String, user: String, install: String, thumbprint: String) -> Data {
        Data("\(domain)\n\(environment)\n\(user)\n\(install)\n\(thumbprint)".utf8)
    }

    /// Registers the presence key `x963` for `install`.
    public func register(presenceKey x963: Data, platform: String, install: PresenceKeyInstall) async throws -> PresenceKeyRegistered {
        let thumbprint = try Self.thumbprint(x963: x963)
        let message = Self.message(environment: install.environment, user: install.user,
                                   install: install.install, thumbprint: thumbprint)
        let signature = try TextConfirmFlow.rawSignature(try await install.sign(message))
        var body: [String: Any] = ["platform": platform, "jwk": try Self.jwk(x963: x963),
                                   "signature": signature.textConfirmBase64URL]
        var keyID: String?
        if platform == "ios" {
            guard let attester else { throw TextConfirmError.attestationUnavailable }
            let id = try await attester.generateKey()
            let attestation = try await attester.attest(keyID: id, clientDataHash: Data(SHA256.hash(data: Data(thumbprint.utf8))))
            body["attestation"] = attestation.textConfirmBase64URL
            body["key_id"] = id
            keyID = id
        }
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (status, reply) = try await transport.post(Self.path, json: json, bearer: try await install.token())
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard (200..<300).contains(status), object?["ok"] as? Bool == true else {
            let code = (object?["error"] as? [String: Any])?["code"] as? String ?? "http.\(status)"
            throw TextConfirmRefusal(code: code)
        }
        return PresenceKeyRegistered(thumbprint: thumbprint, appAttestKeyID: keyID)
    }
}

public enum PresenceKeyError: Error, Hashable, Sendable {
    case invalidPublicKey
}
