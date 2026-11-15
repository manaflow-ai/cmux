import CmuxNextCompat
import Foundation
import Security

/// The Keychain calls an install key's blob needs, on one Keychain service. ``delete(_:)`` answers the status instead
/// of throwing: a refused delete is what ``InstallKeySlots/rotate(make:)`` works around.
protocol InstallKeyKeychain: Sendable {
    /// The accounts of every item of the service (attributes only, never a secret).
    func accounts() async throws -> [String]
    func read(_ account: String) async throws -> Data?
    func add(_ account: String, _ data: Data) async throws
    func delete(_ account: String) async throws -> OSStatus
}

/// Where one install key's blob lives: the account (`install-key-<16 hex>`) or a later generation of it
/// (`install-key-<16 hex>.<n>`, n from 2). The newest generation present is the key.
///
/// Why generations (probe cloud-signed-in-after-update-production, cmux24, 2026-11-15T04:06Z and 04:49Z): the blob
/// is a login (file) Keychain item, and on that Keychain another build of the same bundle id may read an item but
/// not delete it. Build 4366880343301 read the key build 4367130096301 made, its owner answered the key was already
/// registered, and the rotation's SecItemDelete answered errSecInvalidOwnerEdit (-25244): every later mint signed with
/// that retired key and was refused, so the app read signed in and never got a token. A rotation now writes the new
/// key above any item it could not delete, so an update never strands the account on a retired key.
struct InstallKeySlots: Sendable {
    let account: String
    let keychain: any InstallKeyKeychain

    /// The blob of the newest generation, or nil when there is none.
    func current() async throws -> Data? {
        guard let newest = try await generations().last else { return nil }
        return try await keychain.read(name(newest))
    }

    /// Keeps a first key, above any generation present (one that vanished since ``current()`` read nothing).
    func store(_ blob: Data) async throws {
        try await keychain.add(name((try await generations().last ?? 0) + 1), blob)
    }

    /// Retires the key: deletes every generation it may; when one stays, the key `make` gives goes in at once, in
    /// the generation above every kept one, so the retired key is never read again. Throws only when it could not
    /// list, or could neither delete the old key nor add the new one.
    func rotate(make: () async throws -> Data) async throws {
        var kept: [Int] = []
        for generation in try await generations() {
            let status = try await keychain.delete(name(generation))
            if status != errSecSuccess, status != errSecItemNotFound { kept.append(generation) }
        }
        guard let top = kept.max() else { return }
        try await keychain.add(name(top + 1), try await make())
    }

    /// The generations present, oldest first.
    func generations() async throws -> [Int] {
        try await keychain.accounts().compactMap(generation(of:)).sorted()
    }

    func name(_ generation: Int) -> String { generation <= 1 ? account : "\(account).\(generation)" }

    private func generation(of candidate: String) -> Int? {
        if candidate == account { return 1 }
        let suffix = candidate.dropFirst(account.count + 1)
        guard candidate.hasPrefix(account + "."), let number = Int(suffix), number >= 2, String(number) == suffix else { return nil }
        return number
    }
}

/// The login Keychain's generic passwords of `service`, each call through ``BoundedKeychain`` and with no UI.
struct LoginInstallKeyKeychain: InstallKeyKeychain {
    let service: String
    /// The app's one guard of the Keychain UI switch.
    let loginKeychain: LoginKeychain

    func accounts() async throws -> [String] {
        let (service, loginKeychain) = (service, loginKeychain)
        let (status, accounts) = try await BoundedKeychain.run(service: service, account: "*") { () -> (OSStatus, [String]) in
            var query = Self.query(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            var out: CFTypeRef?
            let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
            let items = (out as? [[String: Any]]) ?? (out as? [String: Any]).map { [$0] } ?? []
            return (status, items.compactMap { $0[kSecAttrAccount as String] as? String })
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
        return accounts
    }

    func read(_ account: String) async throws -> Data? {
        let (service, loginKeychain) = (service, loginKeychain)
        let (status, data) = try await BoundedKeychain.run(service: service, account: account) { () -> (OSStatus, Data?) in
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            query[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = loginKeychain.withoutUI { SecItemCopyMatching(query as CFDictionary, &out) }
            return (status, out as? Data)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
        return data
    }

    func add(_ account: String, _ data: Data) async throws {
        let (service, loginKeychain) = (service, loginKeychain)
        let status = try await BoundedKeychain.run(service: service, account: account) {
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // No UI either: a locked or prompting Keychain refuses the add at once.
            return loginKeychain.withoutUI { SecItemAdd(query as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw EnclaveInstallSigner.Failure.keychain(status) }
    }

    func delete(_ account: String) async throws -> OSStatus {
        let (service, loginKeychain) = (service, loginKeychain)
        return try await BoundedKeychain.run(service: service, account: account) {
            var query = Self.query(service: service)
            query[kSecAttrAccount as String] = account
            return loginKeychain.withoutUI { SecItemDelete(query as CFDictionary) }
        }
    }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}
