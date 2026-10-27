#if canImport(Security)
import CryptoKit
import Foundation
import Security
import Testing
@testable import CmuxPhonePush

/// The keychain-backed storage and key material (Apple platforms only).
@Suite("Phone push keychain")
struct PhonePushKeychainTests {
    private static let keychainWritable: Bool = keychainWriteCompletes {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cmux-phone-push-test-probe-\(UUID().uuidString)",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        return status
    }

    private static func keychainWriteCompletes(
        within limit: DispatchTimeInterval = .seconds(5),
        add: @escaping @Sendable () -> OSStatus
    ) -> Bool {
        final class Outcome: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var status: OSStatus = errSecNotAvailable
        }
        let outcome = Outcome()
        Thread.detachNewThread {
            outcome.status = add()
            outcome.done.signal()
        }
        guard outcome.done.wait(timeout: .now() + limit) == .success else { return false }
        return outcome.status == errSecSuccess
    }

    @Test("the keychain group needs a resolved team prefix")
    func keychainAccessGroupResolution() {
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "7WLXT3NR37.dev.cmux.app.internal")
            == "7WLXT3NR37.dev.cmux.app.internal")
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "$(AppIdentifierPrefix)dev.cmux.app") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: ".dev.cmux.app.internal") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: "7WLXT3NR37.") == nil)
        #expect(PhonePushKeychainStateStorage.accessGroup(from: nil) == nil)
    }

    @Test(
        "shared push state migrates to device-only protection",
        .enabled(if: keychainWritable, "no writable keychain (no GUI login session)")
    )
    func sharedPushStateIsDeviceOnly() throws {
        let key = "device-only-\(UUID().uuidString)"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PhonePushKeychainStateStorage.service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(identity as CFDictionary)
        defer { SecItemDelete(identity as CFDictionary) }

        var legacy = identity
        legacy[kSecValueData as String] = Data("legacy-state".utf8)
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        try #require(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess)

        let storage = PhonePushKeychainStateStorage(accessGroup: nil)
        #expect(storage.data(forKey: key) == Data("legacy-state".utf8))
        let current = Data("current-state".utf8)
        storage.setData(current, forKey: key)
        #expect(storage.data(forKey: key) == current)
        #expect(
            PhonePushKeychainStateStorage.keychainAccessibility
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test(
        "phone push key material migrates to device-only protection",
        .enabled(if: keychainWritable, "no writable keychain (no GUI login session)")
    )
    func phonePushKeyMaterialIsDeviceOnly() throws {
        struct LegacyKeyRecord: Encodable {
            let installationID: String
            let keyID: String
            let privateKey: Data
        }

        let bundleID = "cmux-phone-push-test-\(UUID().uuidString)"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.manaflow.cmux.phone-push.\(bundleID)",
            kSecAttrAccount as String: "v1",
        ]
        SecItemDelete(identity as CFDictionary)
        defer { SecItemDelete(identity as CFDictionary) }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let legacyRecord = LegacyKeyRecord(
            installationID: "legacy-installation",
            keyID: "legacy-key",
            privateKey: privateKey.rawRepresentation
        )
        var legacy = identity
        legacy[kSecValueData as String] = try JSONEncoder().encode(legacyRecord)
        legacy[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        try #require(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess)

        let material = try PhonePushKeyMaterial.current(bundleID: bundleID)
        #expect(material.installationID == legacyRecord.installationID)
        #expect(material.keyID == legacyRecord.keyID)
        #expect(
            PhonePushKeyMaterial.keychainAccessibility
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }
}
#endif
