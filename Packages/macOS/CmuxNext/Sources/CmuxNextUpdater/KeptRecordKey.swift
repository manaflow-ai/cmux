public import CryptoKit
import Foundation
import os
import Security

/// The key that authenticates kept-build records (``KeptRecord/mac``): 32 random bytes in a
/// data-protection Keychain item under `<bundle id>.kept-builds`, made on first use. The
/// data-protection Keychain gives an item only to apps of its access group (this app's team and
/// bundle id), never to another process of the same user, and never asks: so a process that
/// changed a kept bundle and wrote a new record for it cannot sign that record. A build that cannot
/// reach that Keychain (an ad hoc DEV build has no access group) gets no key, and its rollbacks
/// check every file of the kept build at the click, as before records.
nonisolated public final class KeptRecordKey: Sendable {
    /// Keys already read, by bundle id: the updater owns one cache for the app's life.
    private let known = OSAllocatedUnfairLock<[String: SymmetricKey]>(initialState: [:])

    public init() {}

    /// The key for `bundleIdentifier`'s kept builds; read once per launch.
    func key(bundleIdentifier: String) -> SymmetricKey? {
        if let key = known.withLock({ $0[bundleIdentifier] }) { return key }
        guard let key = Self.readOrMake(service: "\(bundleIdentifier).kept-builds") else { return nil }
        known.withLock { $0[bundleIdentifier] = key }
        return key
    }

    private static func readOrMake(service: String) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "record-key", kSecAttrSynchronizable as String: false,
                                    kSecUseDataProtectionKeychain as String: true]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, data.count == 32 { return SymmetricKey(data: data) }
        // A Keychain that cannot answer now (locked, no access group): no key this launch, never a
        // new one beside a stored one (it would void every record).
        guard status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}
