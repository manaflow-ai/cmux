import CryptoKit
import Foundation
import Security

/// The identity boundary authenticated by a phone-push envelope. Optional
/// fields are omitted from the canonical form so a relay never needs account
/// secrets to route an already encrypted message.
public struct PhonePushDeviceTuple: Codable, Equatable, Hashable, Sendable {
    public let accountID: String?
    public let teamID: String?
    public let iosBuildID: String
    public let iosInstallationID: String
    public let macDeviceID: String?
    public let macInstanceTag: String?
    public let macBuildID: String?

    public init(
        accountID: String?,
        teamID: String?,
        iosBuildID: String,
        iosInstallationID: String,
        macDeviceID: String?,
        macInstanceTag: String?,
        macBuildID: String?
    ) {
        self.accountID = accountID
        self.teamID = teamID
        self.iosBuildID = iosBuildID
        self.iosInstallationID = iosInstallationID
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macBuildID = macBuildID
    }
}

public struct PhonePushEncryptedPayload: Codable, Equatable, Sendable {
    public let installationID: String
    public let keyID: String
    public let version: Int
    public let ephemeralPublicKey: String
    public let nonce: String
    public let ciphertext: String

    public init(
        installationID: String,
        keyID: String,
        version: Int = 1,
        ephemeralPublicKey: String,
        nonce: String,
        ciphertext: String
    ) {
        self.installationID = installationID
        self.keyID = keyID
        self.version = version
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

public struct PhonePushRecipient: Codable, Equatable, Sendable {
    public let installationID: String
    public let keyID: String
    public let publicKey: Data
    public let bundleID: String

    public init(installationID: String, keyID: String, publicKey: Data, bundleID: String) {
        self.installationID = installationID
        self.keyID = keyID
        self.publicKey = publicKey
        self.bundleID = bundleID
    }
}

public enum PhonePushCryptoError: Error, Sendable {
    case invalidKey
    case invalidEnvelope
    case authenticationFailed
    case keychain(OSStatus)
}

public enum PhonePushCrypto {
    public static let algorithm = "x25519-hkdf-sha256-chacha20poly1305-v1"

    public static func encrypt(
        plaintext: Data,
        tuple: PhonePushDeviceTuple,
        recipientPublicKey: Data,
        keyID: String,
        installationID: String
    ) throws -> PhonePushEncryptedPayload {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("cmux-phone-push-v1".utf8),
            sharedInfo: aad(tuple: tuple, keyID: keyID),
            outputByteCount: 32
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad(tuple: tuple, keyID: keyID))
        return PhonePushEncryptedPayload(
            installationID: installationID,
            keyID: keyID,
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealed.ciphertext + sealed.tag
                .withUnsafeBytes { Data($0) }.base64EncodedString()
        )
    }

    public static func decrypt(
        envelope: PhonePushEncryptedPayload,
        tuple: PhonePushDeviceTuple,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        guard envelope.version == 1,
              let ephemeralData = Data(base64Encoded: envelope.ephemeralPublicKey),
              let nonceData = Data(base64Encoded: envelope.nonce),
              let combined = Data(base64Encoded: envelope.ciphertext),
              combined.count >= 16 else { throw PhonePushCryptoError.invalidEnvelope }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("cmux-phone-push-v1".utf8),
            sharedInfo: aad(tuple: tuple, keyID: envelope.keyID),
            outputByteCount: 32
        )
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let sealed = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: Data(combined.dropLast(16)),
                tag: Data(combined.suffix(16))
            )
            return try ChaChaPoly.open(sealed, using: key, authenticating: aad(tuple: tuple, keyID: envelope.keyID))
        } catch {
            throw PhonePushCryptoError.authenticationFailed
        }
    }

    private static func aad(tuple: PhonePushDeviceTuple, keyID: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tupleData = (try? encoder.encode(tuple)) ?? Data()
        return Data("\(algorithm)|\(keyID)|".utf8) + tupleData
    }
}

/// Separate application key material. Iroh signing keys are intentionally not
/// reused for notification encryption.
public struct PhonePushKeyMaterial: Sendable {
    public let installationID: String
    public let keyID: String
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }

    public init(
        installationID: String,
        keyID: String,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.installationID = installationID
        self.keyID = keyID
        self.privateKey = privateKey
    }
}

public enum PhonePushKeyStore {
    public static func current(bundleID: String, accessGroup: String? = nil) throws -> PhonePushKeyMaterial {
        let service = "ai.manaflow.cmux.phone-push.\(bundleID)"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "v1",
            kSecReturnData as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let data: Data
        if status == errSecItemNotFound {
            let material = PhonePushKeyMaterial(
                installationID: UUID().uuidString.lowercased(),
                keyID: UUID().uuidString.lowercased(),
                privateKey: Curve25519.KeyAgreement.PrivateKey()
            )
            let encoded = try JSONEncoder().encode(KeyRecord(material))
            var item = query
            item[kSecValueData as String] = encoded
            item[kSecReturnData as String] = nil
            if let accessGroup { item[kSecAttrAccessGroup as String] = accessGroup }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PhonePushCryptoError.keychain(addStatus) }
            return material
        } else if status == errSecSuccess, let result = result as? Data {
            data = result
        } else {
            throw PhonePushCryptoError.keychain(status)
        }
        return try KeyRecord.decode(data).material
    }

    private struct KeyRecord: Codable {
        let installationID: String
        let keyID: String
        let privateKey: Data

        init(_ material: PhonePushKeyMaterial) {
            installationID = material.installationID
            keyID = material.keyID
            privateKey = material.privateKey.rawRepresentation
        }

        var material: PhonePushKeyMaterial {
            get throws {
                PhonePushKeyMaterial(
                    installationID: installationID,
                    keyID: keyID,
                    privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
                )
            }
        }

        static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    }
}

public enum PhonePushPeerKeyStore {
    private static let prefix = "cmux.phone-push.peer."

    public static func save(_ publicKey: Data, macDeviceID: String, instanceTag: String?) {
        let key = prefix + macDeviceID + "." + (instanceTag ?? "default")
        UserDefaults.standard.set(publicKey.base64EncodedString(), forKey: key)
    }

    public static func load(macDeviceID: String, instanceTag: String?) -> Data? {
        let key = prefix + macDeviceID + "." + (instanceTag ?? "default")
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        return Data(base64Encoded: value)
    }
}
