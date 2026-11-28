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

public struct PhonePushReplyFreshness: Sendable {
    public init() {}

    public let clockSkew: TimeInterval = 30
    public let maximumLifetime: TimeInterval = 15 * 60

    public func accepts(
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

public struct PhonePushCrypto: Sendable {
    public init() {}

    public let algorithm = "x25519-hpke-sha256-chacha20poly1305-v2"

    public func encrypt(
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

    public func decrypt(
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

    private func info(
        tuple: PhonePushDeviceTuple,
        keyID: String,
        senderKeyID: String
    ) -> Data {
        Data("cmux-phone-push-v2|\(keyID)|\(senderKeyID)|".utf8)
            + canonicalTupleData(tuple)
    }

    private func aad(
        tuple: PhonePushDeviceTuple,
        keyID: String,
        senderKeyID: String
    ) -> Data {
        Data("cmux-phone-push-v2|\(keyID)|\(senderKeyID)|".utf8)
            + canonicalTupleData(tuple)
    }

    private func canonicalTupleData(_ tuple: PhonePushDeviceTuple) -> Data {
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

extension PhonePushKeyMaterial {
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

public struct PhonePushPeerKeyStore {
    private static let prefix = "cmux.phone-push.peer.v2."
    private static let registryKey = prefix + "registry"
    private static let maximumEntries = 128
    private static let lock = NSLock()
    private let storage: any PhonePushSharedStateStorage

    public init(storage: (any PhonePushSharedStateStorage)? = nil) {
        self.storage = storage ?? Bundle.main.phonePushSharedStateStorage
    }

    public func pin(_ descriptor: PhonePushPeerDescriptor, for tuple: PhonePushDeviceTuple) {
        guard !descriptor.keyID.isEmpty else { return }
        Self.lock.withLock {
            let storageKey = key(for: tuple)
            storage.setData(try? JSONEncoder().encode(descriptor), forKey: storageKey)
            var orderedKeys = storage.data(forKey: Self.registryKey)
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let discoveredKeys = storage.keys(withPrefix: Self.prefix).filter {
                $0 != Self.registryKey
            }
            for discoveredKey in discoveredKeys where !orderedKeys.contains(discoveredKey) {
                orderedKeys.append(discoveredKey)
            }
            orderedKeys.removeAll { $0 == storageKey }
            orderedKeys.append(storageKey)
            while orderedKeys.count > Self.maximumEntries {
                let staleKey = orderedKeys.removeFirst()
                storage.setData(nil, forKey: staleKey)
            }
            storage.setData(try? JSONEncoder().encode(orderedKeys), forKey: Self.registryKey)
        }
    }

    public func pin(_ publicKey: Data, keyID: String, for tuple: PhonePushDeviceTuple) {
        pin(PhonePushPeerDescriptor(keyID: keyID, publicKey: publicKey), for: tuple)
    }

    public func pinnedDescriptor(for tuple: PhonePushDeviceTuple) -> PhonePushPeerDescriptor? {
        Self.lock.withLock {
            guard let data = storage.data(forKey: key(for: tuple)) else { return nil }
            return try? JSONDecoder().decode(PhonePushPeerDescriptor.self, from: data)
        }
    }

    public func pinnedKey(for tuple: PhonePushDeviceTuple) -> Data? {
        pinnedDescriptor(for: tuple)?.publicKey
    }

    public func save(_ publicKey: Data, macDeviceID: String, instanceTag: String?) {
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

    public func load(macDeviceID: String, instanceTag: String?) -> Data? {
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

    private func key(for tuple: PhonePushDeviceTuple) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(tuple)) ?? Data()
        return Self.prefix + data.base64EncodedString()
    }
}

public struct PhonePushActiveAccountStore {
    private static let accountKeyPrefix = "cmux.activeAccountID."
    private static let lock = NSLock()

    private let bundle: Bundle
    private let storage: any PhonePushSharedStateStorage

    public init(
        bundle: Bundle = .main,
        storage: (any PhonePushSharedStateStorage)? = nil
    ) {
        self.bundle = bundle
        self.storage = storage ?? bundle.phonePushSharedStateStorage
    }

    private var hostBundleIdentifier: String? {
        let hostID = bundle.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String
        let value = hostID ?? bundle.bundleIdentifier
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func accountKey(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return Self.accountKeyPrefix + bundleID
    }

    public func current() -> String? {
        Self.lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return nil }
            return storage.data(forKey: key).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    public func set(_ accountID: String) {
        Self.lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return }
            storage.setData(Data(accountID.utf8), forKey: key)
        }
    }

    public func clear() {
        Self.lock.withLock {
            guard let key = accountKey(bundleID: hostBundleIdentifier) else { return }
            storage.setData(nil, forKey: key)
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
