public import Foundation
import CryptoKit

/// A Curve25519 key in WireGuard's encoding: 32 raw bytes, shown as base64
/// in configuration and as hex in the UAPI.
public struct WireGuardKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == 32 else { return nil }
        self.rawValue = rawValue
    }

    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(rawValue: data)
    }

    /// A new random private key.
    public init() {
        rawValue = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    /// Thirty-two random bytes, for a preshared key.
    public init(randomPresharedKey: Void) {
        rawValue = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public var base64: String { rawValue.base64EncodedString() }
    public var hex: String { rawValue.map { String(format: "%02x", $0) }.joined() }

    /// The public key for this private key.
    public var publicKey: WireGuardKey {
        // CryptoKit clamps the scalar exactly as WireGuard does.
        let key = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawValue)
        return WireGuardKey(rawValue: key.publicKey.rawRepresentation)!
    }

    /// A short, human-checkable fingerprint ("A1B2-C3D4").
    public var fingerprint: String {
        let digest = SHA256.hash(data: rawValue).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(digest.prefix(4))-\(digest.suffix(4))"
    }

    public var description: String { "WireGuardKey(\(fingerprint))" }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = WireGuardKey(base64: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a 32-byte base64 key"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }
}
