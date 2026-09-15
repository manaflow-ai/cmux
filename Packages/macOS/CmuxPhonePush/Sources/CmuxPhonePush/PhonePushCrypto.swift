public import CryptoKit
public import Foundation
public import Security

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
    public let senderKeyID: String
    public let encapsulatedKey: String
    public let ciphertext: String
    public let tuple: PhonePushDeviceTuple

    public init(
        installationID: String,
        keyID: String,
        version: Int = 2,
        senderKeyID: String,
        encapsulatedKey: String,
        ciphertext: String,
        tuple: PhonePushDeviceTuple
    ) {
        self.installationID = installationID
        self.keyID = keyID
        self.version = version
        self.senderKeyID = senderKeyID
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.tuple = tuple
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

public struct PhonePushPeerDescriptor: Codable, Equatable, Sendable {
    public let keyID: String
    public let publicKey: Data

    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }
}

public enum PhonePushCryptoError: Error, Sendable {
    case invalidKey
    case invalidEnvelope
    case authenticationFailed
    case keychain(OSStatus)
}

public enum PhonePushReplyFreshness {
    public static let clockSkew: TimeInterval = 30
    public static let maximumLifetime: TimeInterval = 15 * 60

    public static func accepts(
        issuedAt: TimeInterval,
        expiresAt: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        issuedAt <= now + clockSkew
            && expiresAt >= now - clockSkew
            && expiresAt > issuedAt
            && expiresAt - issuedAt <= maximumLifetime
    }
}

public enum PhonePushCrypto {
    public static let algorithm = "x25519-hpke-sha256-chacha20poly1305-v2"

    public static func encrypt(
        plaintext: Data,
        tuple: PhonePushDeviceTuple,
        recipientPublicKey: Data,
        keyID: String,
        senderKeyID: String,
        senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        installationID: String
    ) throws -> PhonePushEncryptedPayload {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let info = info(tuple: tuple, keyID: keyID, senderKeyID: senderKeyID)
        var sender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info,
            authenticatedBy: senderPrivateKey
        )
        let ciphertext = try sender.seal(plaintext, authenticating: aad(tuple: tuple, keyID: keyID, senderKeyID: senderKeyID))
        return PhonePushEncryptedPayload(
            installationID: installationID,
            keyID: keyID,
            senderKeyID: senderKeyID,
            encapsulatedKey: sender.encapsulatedKey.base64EncodedString(),
            ciphertext: ciphertext.base64EncodedString(),
            tuple: tuple
        )
    }

    public static func decrypt(
        envelope: PhonePushEncryptedPayload,
        tuple: PhonePushDeviceTuple,
        recipientInstallationID: String,
        recipientKeyID: String,
        trustedSenderKeyID: String,
        senderPublicKey: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        guard envelope.version == 2,
              envelope.installationID == recipientInstallationID,
              envelope.keyID == recipientKeyID,
              envelope.senderKeyID == trustedSenderKeyID,
              envelope.tuple == tuple,
              let encapsulatedData = Data(base64Encoded: envelope.encapsulatedKey),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublicKey)
        else { throw PhonePushCryptoError.invalidEnvelope }
        do {
            var recipient = try HPKE.Recipient(
                privateKey: privateKey,
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: info(
                    tuple: tuple,
                    keyID: envelope.keyID,
                    senderKeyID: envelope.senderKeyID
                ),
                encapsulatedKey: encapsulatedData,
                authenticatedBy: sender
            )
            return try recipient.open(
                ciphertext,
                authenticating: aad(
                    tuple: tuple,
                    keyID: envelope.keyID,
                    senderKeyID: envelope.senderKeyID
                )
            )
        } catch {
            throw PhonePushCryptoError.authenticationFailed
        }
    }

    private static func info(
        tuple: PhonePushDeviceTuple,
        keyID: String,
        senderKeyID: String
    ) -> Data {
        Data("cmux-phone-push-v2|\(keyID)|\(senderKeyID)|".utf8)
            + canonicalTupleData(tuple)
    }

    private static func aad(
        tuple: PhonePushDeviceTuple,
        keyID: String,
        senderKeyID: String
    ) -> Data {
        Data("cmux-phone-push-v2|\(keyID)|\(senderKeyID)|".utf8)
            + canonicalTupleData(tuple)
    }

    private static func canonicalTupleData(_ tuple: PhonePushDeviceTuple) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(tuple)) ?? Data()
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
        let accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
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
            item[kSecAttrAccessible as String] = accessibility
            if let accessGroup { item[kSecAttrAccessGroup as String] = accessGroup }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                var existing: CFTypeRef?
                let readStatus = SecItemCopyMatching(query as CFDictionary, &existing)
                guard readStatus == errSecSuccess, let existingData = existing as? Data else {
                    throw PhonePushCryptoError.keychain(readStatus)
                }
                _ = SecItemUpdate(
                    query as CFDictionary,
                    [kSecAttrAccessible as String: accessibility] as CFDictionary
                )
                return try KeyRecord.decode(existingData).material
            }
            guard addStatus == errSecSuccess else { throw PhonePushCryptoError.keychain(addStatus) }
            return material
        } else if status == errSecSuccess, let result = result as? Data {
            data = result
            _ = SecItemUpdate(
                query as CFDictionary,
                [kSecAttrAccessible as String: accessibility] as CFDictionary
            )
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
    private static let prefix = "cmux.phone-push.peer.v2."
    private static let registryKey = prefix + "registry"
    private static let maximumEntries = 128
    private static let lock = NSLock()
    private nonisolated(unsafe) static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: PhonePushActiveAccountStore.appGroupIdentifier) ?? .standard
        #else
        return .standard
        #endif
    }

    public static func pin(_ descriptor: PhonePushPeerDescriptor, for tuple: PhonePushDeviceTuple) {
        guard !descriptor.keyID.isEmpty else { return }
        lock.withLock {
            let storageKey = key(for: tuple)
            defaults.set(try? JSONEncoder().encode(descriptor), forKey: storageKey)
            var orderedKeys = defaults.stringArray(forKey: registryKey) ?? []
            let discoveredKeys = defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix(prefix) && $0 != registryKey
            }
            for discoveredKey in discoveredKeys where !orderedKeys.contains(discoveredKey) {
                orderedKeys.append(discoveredKey)
            }
            orderedKeys.removeAll { $0 == storageKey }
            orderedKeys.append(storageKey)
            while orderedKeys.count > maximumEntries {
                let staleKey = orderedKeys.removeFirst()
                defaults.removeObject(forKey: staleKey)
            }
            defaults.set(orderedKeys, forKey: registryKey)
        }
    }

    public static func pin(_ publicKey: Data, keyID: String, for tuple: PhonePushDeviceTuple) {
        pin(PhonePushPeerDescriptor(keyID: keyID, publicKey: publicKey), for: tuple)
    }

    public static func pinnedDescriptor(for tuple: PhonePushDeviceTuple) -> PhonePushPeerDescriptor? {
        lock.withLock {
            guard let data = defaults.data(forKey: key(for: tuple)) else { return nil }
            return try? JSONDecoder().decode(PhonePushPeerDescriptor.self, from: data)
        }
    }

    public static func pinnedKey(for tuple: PhonePushDeviceTuple) -> Data? {
        pinnedDescriptor(for: tuple)?.publicKey
    }

    public static func save(_ publicKey: Data, macDeviceID: String, instanceTag: String?) {
        let tuple = PhonePushDeviceTuple(
            accountID: nil,
            teamID: nil,
            iosBuildID: "legacy",
            iosInstallationID: "legacy",
            macDeviceID: macDeviceID,
            macInstanceTag: instanceTag,
            macBuildID: nil
        )
        pin(publicKey, keyID: "legacy", for: tuple)
    }

    public static func load(macDeviceID: String, instanceTag: String?) -> Data? {
        let tuple = PhonePushDeviceTuple(
            accountID: nil,
            teamID: nil,
            iosBuildID: "legacy",
            iosInstallationID: "legacy",
            macDeviceID: macDeviceID,
            macInstanceTag: instanceTag,
            macBuildID: nil
        )
        return pinnedKey(for: tuple)
    }

    private static func key(for tuple: PhonePushDeviceTuple) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(tuple)) ?? Data()
        return prefix + data.base64EncodedString()
    }
}

public enum PhonePushActiveAccountStore {
    public static let appGroupIdentifier = "group.dev.cmux.ios"
    private static let accountKeyPrefix = "cmux.activeAccountID."
    private static let lock = NSLock()

    private static var hostBundleIdentifier: String? {
        let bundle = Bundle.main
        let hostID = bundle.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String
        let value = hostID ?? bundle.bundleIdentifier
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func accountKey(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return accountKeyPrefix + bundleID
    }

    public static func current() -> String? {
        lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return nil }
            return UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: key)
        }
    }

    public static func set(_ accountID: String) {
        lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return }
            UserDefaults(suiteName: appGroupIdentifier)?.set(accountID, forKey: key)
        }
    }

    public static func clear() {
        lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return }
            UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: key)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
