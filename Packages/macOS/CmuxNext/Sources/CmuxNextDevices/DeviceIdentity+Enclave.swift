// The macOS app's device identity: P-256 keys in the Secure Enclave, their encrypted blobs in the file
// Keychain (DeviceKeychain). CryptoKit's SecureEnclave and the Keychain exist only on Apple platforms; elsewhere
// (Linux) the composition root injects a `DeviceKeyMaterial` and a `RelaySecretStore` (p15-oracle-141).
#if canImport(Security)
public import CryptoKit
public import Foundation

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

extension DeviceIdentity {
    /// This app's identity: the device id and the Secure Enclave key blobs in
    /// the Keychain under `<bundleIdentifier>.device-hub`, created on first
    /// use. A missing or unreadable part makes a new identity (a new device).
    public static func forApp(bundleIdentifier: String) throws -> DeviceIdentity {
        try load(keychain: DeviceKeychain(service: bundleIdentifier + ".device-hub"))
    }

    /// Forgets this app's identity and makes a new one: the hub refused the old
    /// id (`device_removed`, `device_key_mismatch`), so this is a new device.
    public static func renew(bundleIdentifier: String) throws -> DeviceIdentity {
        let keychain = DeviceKeychain(service: bundleIdentifier + ".device-hub")
        for account in [idAccount, signingAccount, agreementAccount] { try keychain.delete(account) }
        return try load(keychain: keychain)
    }

    static func load(keychain: DeviceKeychain) throws -> DeviceIdentity {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        if let idText = try keychain.read(Self.idAccount).flatMap({ String(data: $0, encoding: .utf8) }),
           let id = UUID(uuidString: idText),
           let signingBlob = try keychain.read(Self.signingAccount),
           let agreementBlob = try keychain.read(Self.agreementAccount),
           let signing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signingBlob),
           let agreement = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreementBlob) {
            return DeviceIdentity(deviceID: id, keys: EnclaveDeviceKeys(signing: signing, agreement: agreement))
        }
        let access = try DeviceKeychain.keyAccessControl()
        let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let id = UUID()
        try keychain.write(signing.dataRepresentation, account: Self.signingAccount)
        try keychain.write(agreement.dataRepresentation, account: Self.agreementAccount)
        try keychain.write(Data(id.uuidString.lowercased().utf8), account: Self.idAccount)
        return DeviceIdentity(deviceID: id, keys: EnclaveDeviceKeys(signing: signing, agreement: agreement))
    }

    static let idAccount = "device-id"
    static let signingAccount = "device-signing-key"
    static let agreementAccount = "device-agreement-key"
}
#endif
