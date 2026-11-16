internal import CCmuxLayoutReducerFFI
public import CmuxNextCompat
public import CryptoKit
public import Foundation
import Security

/// The two P-256 private keys of this device (docs/device-hub/PROTOCOL.md,
/// Identity): one signs requests and session fingerprints, one opens relay
/// secrets sealed to it with HPKE. The app's keys live in the Secure Enclave
/// (``EnclaveDeviceKeys``); tests inject software keys.
public protocol DeviceKeyMaterial: Sendable {
    var signingPublicKey: P256.Signing.PublicKey { get }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { get }
    /// ECDSA-P256-SHA256 over `message`.
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature
    /// Opens one HPKE (P-256, HKDF-SHA256, AES-GCM) message sealed to the agreement key.
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data
}

/// This device's keys in the Secure Enclave. Only the enclave's encrypted
/// key blobs are stored (``DeviceKeychain``); the private keys never leave it.
public struct EnclaveDeviceKeys: DeviceKeyMaterial {
    let signing: SecureEnclave.P256.Signing.PrivateKey
    let agreement: SecureEnclave.P256.KeyAgreement.PrivateKey

    public var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    public var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }

    public func signature(for message: Data) throws -> P256.Signing.ECDSASignature {
        try signing.signature(for: message)
    }

    public func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                           encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext)
    }
}

/// Who this device is to the device hub: a per-app-bundle id and its keys.
/// Tagged builds have their own bundle id, so each is its own device.
public struct DeviceIdentity: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case secureEnclaveUnavailable
        case keychain(OSStatus)
        case corruptKeyBlob
        /// The app's Rust rules (`cloud_identity_device_slots`) did not answer.
        case rulesUnanswered
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

extension DeviceIdentity {
    /// This app's identity: the device id and the Secure Enclave key blobs in
    /// the Keychain under `<bundleIdentifier>.device-hub`, created on first
    /// use. A missing or unreadable part makes a new identity (a new device).
    public static func forApp(bundleIdentifier: String, loginKeychain: LoginKeychain) throws -> DeviceIdentity {
        try load(keychain: DeviceKeychain(service: bundleIdentifier + ".device-hub", loginKeychain: loginKeychain), keys: .enclave)
    }

    /// Forgets this app's identity and makes a new one: the hub refused the old
    /// id (`device_removed`, `device_key_mismatch`), so this is a new device.
    public static func renew(bundleIdentifier: String, loginKeychain: LoginKeychain) throws -> DeviceIdentity {
        try renew(keychain: DeviceKeychain(service: bundleIdentifier + ".device-hub", loginKeychain: loginKeychain), keys: .enclave)
    }

    /// Deletes every item of the identity it can and adds a new one where Rust says: above every item it could
    /// not delete (another build's, after an update: errSecInvalidOwnerEdit), so the refused id is never read again.
    static func renew(keychain: any DeviceIdentityKeychain, keys: DeviceKeyBlobs) throws -> DeviceIdentity {
        let present = try Slots.ask(accounts: try keychain.accountsThrowing()).accounts
        let deletes = present.map { Slots.Delete(account: $0, status: keychain.deleteStatus($0)) }
        return try make(at: try Slots.ask(deletes: deletes).replacement, keychain: keychain, keys: keys)
    }

    /// The newest generation's identity (Rust's `current`); a missing or unreadable part of it renews, never
    /// reading an older generation.
    static func load(keychain: any DeviceIdentityKeychain, keys: DeviceKeyBlobs) throws -> DeviceIdentity {
        if let current = try Slots.ask(accounts: try keychain.accountsThrowing()).current,
           let idText = try keychain.read(current.id).flatMap({ String(data: $0, encoding: .utf8) }),
           let id = UUID(uuidString: idText),
           let signingBlob = try keychain.read(current.signingKey),
           let agreementBlob = try keychain.read(current.agreementKey),
           let material = try keys.open(signingBlob, agreementBlob) {
            return DeviceIdentity(deviceID: id, keys: material)
        }
        return try renew(keychain: keychain, keys: keys)
    }

    private static func make(at slot: Slots.Generation, keychain: any DeviceIdentityKeychain,
                             keys: DeviceKeyBlobs) throws -> DeviceIdentity {
        let made = try keys.make()
        let id = UUID()
        try keychain.add(made.signing, account: slot.signingKey)
        try keychain.add(made.agreement, account: slot.agreementKey)
        try keychain.add(Data(id.uuidString.lowercased().utf8), account: slot.id)
        return DeviceIdentity(deviceID: id, keys: made.keys)
    }

    /// The identity's items among a service's `accounts`, every generation: the only identity items a protected
    /// capture may remove.
    public static func identityAccounts(among accounts: [String]) throws -> [String] {
        try Slots.ask(accounts: accounts).accounts
    }

    /// Rust's answer (`cloud_identity_device_slots`, cmux-cloud-config `device_identity_slots`): every item of the
    /// identity present (oldest generation first), the generation to read, and where a new identity goes from the
    /// deletes a renewal made. Swift makes the Keychain calls; Rust decides which items.
    struct Slots: Decodable {
        struct Generation: Decodable { var id: String, signingKey: String, agreementKey: String }
        struct Delete: Encodable { var account: String, status: OSStatus }
        var accounts: [String]
        var current: Generation?
        var replacement: Generation

        static func ask(accounts: [String] = [], deletes: [Delete] = []) throws -> Slots {
            struct Request: Encodable { var accounts: [String], deletes: [Delete] }
            guard let request = try? JSONEncoder().encode(Request(accounts: accounts, deletes: deletes)),
                  let reply = call("cloud_identity_device_slots", request),
                  let slots = try? JSONDecoder().decode(Slots.self, from: reply) else { throw Failure.rulesUnanswered }
            return slots
        }

        /// One JSON call of the app FFI (`cmux_layout_reducer_json`); nil when it does not answer.
        private static func call(_ operation: String, _ request: Data) -> Data? {
            var capacity = 4096
            for _ in 0..<2 {
                var output = [UInt8](repeating: 0, count: capacity)
                var length = 0
                let code: Int32 = request.withUnsafeBytes { bytes in
                    operation.withCString { op in
                        output.withUnsafeMutableBytes { out in
                            cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                     out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                        }
                    }
                }
                if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
                guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
                return Data(output.prefix(length))
            }
            return nil
        }
    }
}

/// The device keys as the Keychain keeps them: the Secure Enclave's encrypted blobs in the app
/// (``enclave``), software keys in tests.
struct DeviceKeyBlobs: Sendable {
    /// A new pair of keys and the blobs to store.
    var make: @Sendable () throws -> (keys: any DeviceKeyMaterial, signing: Data, agreement: Data)
    /// The keys of stored blobs; nil when they are not (a new identity replaces them).
    var open: @Sendable (_ signing: Data, _ agreement: Data) throws -> (any DeviceKeyMaterial)?

    static let enclave = DeviceKeyBlobs(
        make: {
            guard SecureEnclave.isAvailable else { throw DeviceIdentity.Failure.secureEnclaveUnavailable }
            let access = try DeviceKeychain.keyAccessControl()
            let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            return (EnclaveDeviceKeys(signing: signing, agreement: agreement), signing.dataRepresentation, agreement.dataRepresentation)
        },
        open: { signing, agreement in
            guard SecureEnclave.isAvailable else { throw DeviceIdentity.Failure.secureEnclaveUnavailable }
            guard let signing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signing),
                  let agreement = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreement) else { return nil }
            return EnclaveDeviceKeys(signing: signing, agreement: agreement)
        })
}
