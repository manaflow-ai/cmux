#if canImport(CryptoKit)
public import CryptoKit
#else
public import Crypto
#endif
public import Foundation

/// The two P-256 private keys of this device (docs/device-hub/PROTOCOL.md,
/// Identity): one signs requests and session fingerprints, one opens relay
/// secrets sealed to it with HPKE. The macOS app's keys live in the Secure Enclave
/// (`EnclaveDeviceKeys`, DeviceIdentity+Enclave.swift); tests inject software keys.
public protocol DeviceKeyMaterial: Sendable {
    var signingPublicKey: P256.Signing.PublicKey { get }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { get }
    /// ECDSA-P256-SHA256 over `message`.
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature
    /// Opens one HPKE (P-256, HKDF-SHA256, AES-GCM) message sealed to the agreement key.
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data
}

/// Who this device is to the device hub: a per-app-bundle id and its keys.
/// Tagged builds have their own bundle id, so each is its own device.
public struct DeviceIdentity: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case secureEnclaveUnavailable
        /// A Keychain call returned this `OSStatus` (an `Int32`, spelled so for the platforms without Security).
        case keychain(Int32)
        case corruptKeyBlob
    }

    public let deviceID: UUID
    public let keys: any DeviceKeyMaterial

    public init(deviceID: UUID, keys: any DeviceKeyMaterial) {
        self.deviceID = deviceID
        self.keys = keys
    }

    /// The id on the wire: the UUID, lowercase.
    public var id: String { deviceID.uuidString.lowercased() }
    /// The signing key as base64 of its X9.63 uncompressed point (65 bytes).
    public var signingKey: String { keys.signingPublicKey.x963Representation.base64EncodedString() }
    /// The key agreement key as base64 of its X9.63 uncompressed point.
    public var agreementKey: String { keys.agreementPublicKey.x963Representation.base64EncodedString() }
    /// The signing key's fingerprint, as the hub sends it (`viewerKeyFingerprint`).
    public var fingerprint: String { Self.fingerprint(signingKeyX963: keys.signingPublicKey.x963Representation) }

    /// The lowercase hex SHA-256 of a signing key's 65 X9.63 bytes (PROTOCOL.md, `viewerKeyFingerprint`).
    public static func fingerprint(signingKeyX963 key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    /// The fingerprint of a base64 X9.63 signing key (another device's), or nil when it is not one.
    public static func fingerprint(signingKey base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), (try? P256.Signing.PublicKey(x963Representation: data)) != nil else { return nil }
        return fingerprint(signingKeyX963: data)
    }

    /// A fingerprint for people to compare: its first 32 hex digits, uppercase,
    /// in eight groups of four (`1A2B 3C4D …`).
    public static func displayFingerprint(_ fingerprint: String) -> String {
        let hex = Array(fingerprint.uppercased().prefix(32))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0 ..< min($0 + 4, hex.count)]) }.joined(separator: " ")
    }

    /// base64 of the raw r||s (64 bytes) ECDSA-P256-SHA256 signature of `canonical`'s UTF-8 bytes.
    public func sign(canonical: String) throws -> String {
        try sign(Data(canonical.utf8)).base64EncodedString()
    }

    /// The raw r||s signature (64 bytes) of `message`.
    public func sign(_ message: Data) throws -> Data {
        try keys.signature(for: message).rawRepresentation
    }

    /// Whether `signature` (base64 raw r||s) is `signingKey`'s (base64 X9.63) signature of `message`.
    public static func verify(signature: String, of message: Data, signingKey: String) -> Bool {
        guard let raw = Data(base64Encoded: signature), let keyData = Data(base64Encoded: signingKey),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(parsed, for: message)
    }
}
