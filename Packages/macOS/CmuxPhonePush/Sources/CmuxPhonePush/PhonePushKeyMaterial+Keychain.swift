#if canImport(Security)
import CryptoKit
import Foundation
import Security

extension PhonePushKeyMaterial {
    static let keychainAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    public static func current(bundleID: String, accessGroup: String? = nil) throws -> PhonePushKeyMaterial {
        let service = "ai.manaflow.cmux.phone-push.\(bundleID)"
        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "v1",
        ]
        if let accessGroup { identity[kSecAttrAccessGroup as String] = accessGroup }
        var query = identity
        query[kSecReturnData as String] = true
        let accessibility = keychainAccessibility
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
            var item = identity
            item[kSecValueData as String] = encoded
            item[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                var existing: CFTypeRef?
                let readStatus = SecItemCopyMatching(query as CFDictionary, &existing)
                guard readStatus == errSecSuccess, let existingData = existing as? Data else {
                    throw PhonePushCryptoError.keychain(readStatus)
                }
                let migrationStatus = SecItemUpdate(
                    identity as CFDictionary,
                    [kSecAttrAccessible as String: accessibility] as CFDictionary
                )
                guard migrationStatus == errSecSuccess else {
                    throw PhonePushCryptoError.keychain(migrationStatus)
                }
                return try KeyRecord.decode(existingData).material
            }
            guard addStatus == errSecSuccess else { throw PhonePushCryptoError.keychain(addStatus) }
            return material
        } else if status == errSecSuccess, let result = result as? Data {
            data = result
            let migrationStatus = SecItemUpdate(
                identity as CFDictionary,
                [kSecAttrAccessible as String: accessibility] as CFDictionary
            )
            guard migrationStatus == errSecSuccess else {
                throw PhonePushCryptoError.keychain(migrationStatus)
            }
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
#endif
