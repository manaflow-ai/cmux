public import Foundation
#if canImport(Security)
import Security
#endif

/// Reads, writes, and verifies the local control-socket password.
///
/// Constructed at the app's startup site and injected where socket auth is performed
/// (rather than reached through a global). All collaborators (environment, the password
/// file URL, and the legacy keychain load/delete operations) are injected, so the store
/// is fully testable against a temp file and a fake keychain.
///
/// The password sources, highest priority first, are the `CMUX_SOCKET_PASSWORD`
/// environment variable, the password file, and (only when `allowLazyKeychainFallback`
/// is set) the legacy keychain entry.
public struct SocketControlPasswordStore: Sendable {
    /// Posted after the password file is written or cleared, so observers can re-read it.
    public static let didChangeNotification = Notification.Name("cmux.socketControlPasswordDidChange")

    /// Default Application Support subdirectory holding the password file.
    public static let directoryName = "cmux"
    /// Default password file name.
    public static let fileName = "socket-control-password"

    private static let keychainMigrationDefaultsKey = "socketControlPasswordMigrationVersion"
    private static let keychainMigrationVersion = 1
    private static let legacyKeychainService = "com.cmuxterm.app.socket-control"
    private static let legacyKeychainAccount = "local-socket-password"

    private let environment: [String: String]
    private let fileURLOverride: URL?
    private let loadKeychainPassword: @Sendable () -> String?
    private let deleteKeychainPassword: @Sendable () -> Bool
    // FileManager is Apple-documented thread-safe for the file operations used here
    // (existence checks, directory creation, attribute writes, removal), so it is safe
    // to read from the synchronous, `nonisolated` socket-auth path without isolation.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a password store backed by the real legacy keychain.
    /// - Parameters:
    ///   - environment: The process environment used to read `CMUX_SOCKET_PASSWORD`.
    ///   - fileURL: An explicit password file URL; defaults to the Application Support location.
    ///   - fileManager: The file manager used to read and write the password file; defaults to `.default`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        // An init body (unlike a default-argument value) may reference private statics,
        // so the real keychain accessors stay private to the type.
        self.init(
            environment: environment,
            fileURL: fileURL,
            fileManager: fileManager,
            loadKeychainPassword: { Self.loadLegacyPasswordFromKeychain() },
            deleteKeychainPassword: { Self.deleteLegacyPasswordFromKeychain() }
        )
    }

    /// Creates a password store with explicit keychain accessors, for testing.
    /// - Parameters:
    ///   - environment: The process environment used to read `CMUX_SOCKET_PASSWORD`.
    ///   - fileURL: An explicit password file URL; defaults to the Application Support location.
    ///   - fileManager: The file manager used to read and write the password file; defaults to `.default`.
    ///   - loadKeychainPassword: Reads the legacy keychain password.
    ///   - deleteKeychainPassword: Deletes the legacy keychain entry.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        loadKeychainPassword: @escaping @Sendable () -> String?,
        deleteKeychainPassword: @escaping @Sendable () -> Bool
    ) {
        self.environment = environment
        self.fileURLOverride = fileURL
        self.fileManager = fileManager
        self.loadKeychainPassword = loadKeychainPassword
        self.deleteKeychainPassword = deleteKeychainPassword
    }

    /// The configured password from the highest-priority available source, if any.
    /// - Parameter allowLazyKeychainFallback: Whether to consult the legacy keychain as a last resort.
    /// - Returns: The configured password, or `nil` when none is set.
    public func configuredPassword(allowLazyKeychainFallback: Bool = false) -> String? {
        if let envPassword = Self.normalized(environment[SocketControlSettings.socketPasswordEnvKey]) {
            return envPassword
        }
        if let filePassword = (try? loadPassword()) ?? nil {
            return filePassword
        }
        guard allowLazyKeychainFallback else {
            return nil
        }
        // The legacy keychain is the lowest-priority source and is only consulted
        // when neither the environment nor the file holds a password. In steady
        // state the file holds it (the keychain entry is migrated then deleted),
        // so this read is rare; reading on demand keeps the store free of shared
        // mutable state (no lock, trivially `Sendable`).
        return Self.normalized(loadKeychainPassword())
    }

    /// Whether a non-empty password is configured.
    /// - Parameter allowLazyKeychainFallback: Whether to consult the legacy keychain as a last resort.
    public func hasConfiguredPassword(allowLazyKeychainFallback: Bool = false) -> Bool {
        guard let configured = configuredPassword(allowLazyKeychainFallback: allowLazyKeychainFallback) else {
            return false
        }
        return !configured.isEmpty
    }

    /// Whether `candidate` matches the configured password.
    /// - Parameters:
    ///   - candidate: The password to check.
    ///   - allowLazyKeychainFallback: Whether to consult the legacy keychain as a last resort.
    /// - Returns: `true` only when a non-empty password is configured and equals `candidate`.
    public func verify(password candidate: String, allowLazyKeychainFallback: Bool = false) -> Bool {
        guard let expected = configuredPassword(allowLazyKeychainFallback: allowLazyKeychainFallback),
              !expected.isEmpty else {
            return false
        }
        return Self.constantTimeEquals(expected, candidate)
    }

    /// Compares two strings in time independent of where they first differ.
    ///
    /// The socket is local-only, so the timing-attack surface is small, but this
    /// is an auth path: a length-and-content comparison that always scans the
    /// full expected password removes any ambiguity about early-exit leakage.
    private static func constantTimeEquals(_ expected: String, _ candidate: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let candidateBytes = Array(candidate.utf8)
        var difference = expectedBytes.count ^ candidateBytes.count
        for index in expectedBytes.indices {
            // Fold every expected byte in; index into candidate safely so a
            // length mismatch never short-circuits the scan.
            let candidateByte = index < candidateBytes.count ? candidateBytes[index] : 0
            difference |= Int(expectedBytes[index] ^ candidateByte)
        }
        return difference == 0
    }

    /// Migrates a legacy keychain password into the password file once, then deletes the keychain entry.
    /// - Parameter defaults: The defaults used to record that migration has run.
    public func migrateLegacyKeychainPasswordIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: Self.keychainMigrationDefaultsKey) < Self.keychainMigrationVersion else {
            return
        }

        guard let legacyPassword = Self.normalized(loadKeychainPassword()) else {
            defaults.set(Self.keychainMigrationVersion, forKey: Self.keychainMigrationDefaultsKey)
            return
        }

        do {
            if try loadPassword() == nil {
                try savePassword(legacyPassword)
            }
            guard deleteKeychainPassword() else {
                return
            }
            defaults.set(Self.keychainMigrationVersion, forKey: Self.keychainMigrationDefaultsKey)
        } catch {
            // Leave migration unset so it retries on next launch.
        }
    }

    /// The password stored in the password file, if present.
    /// - Returns: The trimmed password, or `nil` when the file is absent or empty.
    /// - Throws: If the file exists but cannot be read.
    public func loadPassword() throws -> String? {
        guard let fileURL = resolvedFileURL() else {
            return nil
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        guard let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Self.normalized(password)
    }

    /// Writes the password to the password file (or clears it when empty), then posts ``didChangeNotification``.
    /// - Parameter password: The password to store; an empty/whitespace value clears it.
    /// - Throws: If the file path cannot be resolved or the write fails.
    public func savePassword(_ password: String) throws {
        let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try clearPassword()
            return
        }

        guard let fileURL = resolvedFileURL() else {
            throw SocketControlPasswordStoreError.unresolvedPasswordFilePath
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = Data(normalized.utf8)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Deletes the password file (if present), then posts ``didChangeNotification``.
    /// - Throws: If the file exists but cannot be removed.
    public func clearPassword() throws {
        guard let fileURL = resolvedFileURL() else {
            return
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// The default password file URL within Application Support, if it can be resolved.
    /// - Parameters:
    ///   - appSupportDirectory: An explicit Application Support directory; defaults to the user's.
    ///   - fileManager: The file manager used to resolve Application Support; defaults to `.default`.
    /// - Returns: The password file URL, or `nil` when Application Support cannot be resolved.
    public static func defaultPasswordFileURL(
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func resolvedFileURL() -> URL? {
        fileURLOverride ?? Self.defaultPasswordFileURL(fileManager: fileManager)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadLegacyPasswordFromKeychain() -> String? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.cmuxterm.app.socket-control",
            kSecAttrAccount: "local-socket-password",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    private static func deleteLegacyPasswordFromKeychain() -> Bool {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.cmuxterm.app.socket-control",
            kSecAttrAccount: "local-socket-password",
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
#else
        return false
#endif
    }
}

/// An error thrown while persisting the control-socket password.
public enum SocketControlPasswordStoreError: Error, Equatable, Sendable {
    /// The password file path could not be resolved (Application Support was unavailable).
    case unresolvedPasswordFilePath
}
