public import Foundation
import CmuxNextCompat
#if canImport(Security)
import Security
#endif

public enum CaptureAuthCleanupPhase: String, Sendable {
    case prepare
    case cleanup
}

/// A non-secret proof that the exact auth stores used by this capture are absent.
public struct CaptureAuthCleanupResult: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case ok
        case invalidLease = "invalid_lease"
        case bundleMismatch = "bundle_mismatch"
        case keychainStoreUnavailable = "keychain_store_unavailable"
        case keychainItemPresent = "keychain_item_present"
        case keychainReadFailed = "keychain_read_failed"
        case fileStorePresent = "file_store_present"
        case fileDeleteFailed = "file_delete_failed"
        case markerPresent = "marker_present"
        case ownershipMissing = "ownership_missing"
        case ownershipMismatch = "ownership_mismatch"
        case markerWriteFailed = "marker_write_failed"
        case markerVerificationFailed = "marker_verification_failed"
        case authNotQuiescent = "auth_not_quiescent"
    }

    public let ok: Bool
    public let code: Code
    public let keychainAbsent: Bool
    public let filesAbsent: Bool
    public let verifiedAbsent: Bool

    public init(ok: Bool, code: Code, keychainAbsent: Bool = false, filesAbsent: Bool = false,
                verifiedAbsent: Bool = false) {
        self.ok = ok
        self.code = code
        self.keychainAbsent = keychainAbsent
        self.filesAbsent = filesAbsent
        self.verifiedAbsent = verifiedAbsent
    }

    public static func failure(_ code: Code) -> Self { Self(ok: false, code: code) }
    public static let success = Self(ok: true, code: .ok, keychainAbsent: true, filesAbsent: true, verifiedAbsent: true)
}

/// Exact current and legacy auth persistence for a resolved Cloud configuration.
/// This never reads token values and never performs a global keychain reset.
public struct CaptureAuthPersistence: Sendable {
    public init() {}

    public func run(configuration: CloudConfiguration, phase: CaptureAuthCleanupPhase,
                    leaseID: String, requestedBundleIdentifier: String,
                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CaptureAuthCleanupResult {
        guard validLease(leaseID) else { return .failure(.invalidLease) }
        guard requestedBundleIdentifier == configuration.bundleID, !requestedBundleIdentifier.isEmpty else {
            return .failure(.bundleMismatch)
        }
        let files = filePaths(configuration: configuration, homeDirectory: homeDirectory)
        let marker = markerURL(configuration: configuration, homeDirectory: homeDirectory)
        switch phase {
        case .prepare:
            guard !FileManager.checked.fileExists(atPath: marker.path) else { return .failure(.markerPresent) }
            guard files.allSatisfy({ !FileManager.checked.fileExists(atPath: $0.path) }) else {
                return .failure(.fileStorePresent)
            }
            let keychain = keychainProof(configuration: configuration, delete: false)
            guard keychain.ok else { return keychain }
            do {
                let data = Data((leaseID + "\n" + requestedBundleIdentifier).utf8)
                try FileManager.checked.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.blockingWrite(to: marker, options: [.atomic])
                guard try Data(blockingContentsOf: marker) == data else { return .failure(.markerVerificationFailed) }
            } catch { return .failure(.markerWriteFailed) }
            return CaptureAuthCleanupResult(ok: true, code: .ok, keychainAbsent: true, filesAbsent: true, verifiedAbsent: true)
        case .cleanup:
            guard let markerData = try? Data(blockingContentsOf: marker) else { return .failure(.ownershipMissing) }
            guard markerData == Data((leaseID + "\n" + requestedBundleIdentifier).utf8) else {
                return .failure(.ownershipMismatch)
            }
            let keychain = keychainProof(configuration: configuration, delete: true)
            guard keychain.ok else { return keychain }
            for file in files where FileManager.checked.fileExists(atPath: file.path) {
                do { try FileManager.checked.removeItem(at: file) }
                catch { return .failure(.fileDeleteFailed) }
            }
            guard files.allSatisfy({ !FileManager.checked.fileExists(atPath: $0.path) }) else {
                return .failure(.fileDeleteFailed)
            }
            do {
                try FileManager.checked.removeItem(at: marker)
                guard !FileManager.checked.fileExists(atPath: marker.path) else { return .failure(.markerVerificationFailed) }
            } catch { return .failure(.markerWriteFailed) }
            return .success
        }
    }

    private func filePaths(configuration: CloudConfiguration, homeDirectory: URL) -> [URL] {
        var paths = [configuration.credentialsDirectory(homeDirectory: homeDirectory).appendingPathComponent("credentials.json")]
        if let legacy = configuration.namespacedLegacyStorage(homeDirectory: homeDirectory) {
            paths.append(legacy.credentialsDirectory.appendingPathComponent("credentials.json"))
        }
        return paths
    }

    private func markerURL(configuration: CloudConfiguration, homeDirectory: URL) -> URL {
        configuration.credentialsDirectory(homeDirectory: homeDirectory).appendingPathComponent("capture-auth-lease")
    }

    private func keychainProof(configuration: CloudConfiguration, delete: Bool) -> CaptureAuthCleanupResult {
        #if canImport(Security)
        let current = ["cmux-auth-access-token", "cmux-auth-refresh-token"]
        var queries: [[String: Any]] = current.map { account in
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: configuration.keychainService,
             kSecAttrAccount as String: account,
             kSecUseDataProtectionKeychain as String: true]
        }
        if let legacy = configuration.namespacedLegacyStore {
            queries += current.map { account in
                [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: legacy.keychainService,
                 kSecAttrAccount as String: account,
                 kSecUseDataProtectionKeychain as String: true]
            }
        }
        let legacyAccounts = ["stack-auth-access-\(configuration.stackProjectID)",
                              "stack-auth-refresh-\(configuration.stackProjectID)"]
        queries += legacyAccounts.map { account in
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "",
             kSecAttrAccount as String: account]
        }
        for query in queries {
            var attrs = query
            attrs[kSecReturnAttributes as String] = true
            attrs[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = LoginKeychain().withoutUI { SecItemCopyMatching(attrs as CFDictionary, &result) }
            if status == errSecItemNotFound { continue }
            if status == errSecMissingEntitlement { return .failure(.keychainStoreUnavailable) }
            guard status == errSecSuccess else { return .failure(.keychainReadFailed) }
            if !delete { return .failure(.keychainItemPresent) }
            let deleteStatus = LoginKeychain().withoutUI { SecItemDelete(query as CFDictionary) }
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                return .failure(.keychainReadFailed)
            }
        }
        if delete {
            for query in queries {
                var attrs = query
                attrs[kSecReturnAttributes as String] = true
                attrs[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = LoginKeychain().withoutUI { SecItemCopyMatching(attrs as CFDictionary, &result) }
                if status == errSecItemNotFound { continue }
                if status == errSecMissingEntitlement { return .failure(.keychainStoreUnavailable) }
                guard status == errSecSuccess else { return .failure(.keychainReadFailed) }
                return .failure(.keychainItemPresent)
            }
        }
        return CaptureAuthCleanupResult(ok: true, code: .ok, keychainAbsent: true)
        #else
        return .failure(.keychainStoreUnavailable)
        #endif
    }

    private func validLease(_ value: String) -> Bool {
        value.count == 24 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}
