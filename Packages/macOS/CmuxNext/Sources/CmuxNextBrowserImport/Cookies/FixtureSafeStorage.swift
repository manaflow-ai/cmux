public import Foundation

/// Test launches with a fixture home: passwords from a JSON file
/// (`{"Chrome Safe Storage": "fixture-password"}`), so no real Keychain item
/// is ever read. Used only together with `ImportEnvironment.fixtureHomeKey`.
public struct FixtureSafeStorage: SafeStorageKeyProviding {
    public static let environmentKey = "CMUX_NEXT_BROWSER_IMPORT_KEYS"
    let passwords: [String: String]

    public init(passwords: [String: String]) {
        self.passwords = passwords
    }

    public init?(environment: [String: String], fileManager: FileManager = FileManager()) {
        guard let home = environment[ImportEnvironment.fixtureHomeKey], !home.isEmpty,
              let path = environment[Self.environmentKey], !path.isEmpty,
              let data = fileManager.contents(atPath: path),
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        self.passwords = passwords
    }

    public func password(service: String) throws(CookieImportError) -> SecretBytes {
        guard let password = passwords[service] else { throw .keyNotFound(service: service) }
        return SecretBytes(copying: Array(password.utf8))
    }
}

/// The key provider for this process: the fixture file in a fixture-home
/// test launch, else the login Keychain.
public struct SafeStorageKeys {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let allowsFixtures: Bool

    /// Creates the key provider factory for a process environment.
    ///
    /// - Parameters:
    ///   - environment: Environment used to choose fixture or login Keychain keys.
    ///   - fileManager: Filesystem access for fixture keys.
    ///   - allowsFixtures: Whether the fixture seam is honored (DEBUG builds only by default).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = FileManager(),
                allowsFixtures: Bool = ImportEnvironment.fixturesAllowed) {
        self.environment = environment
        self.fileManager = fileManager
        self.allowsFixtures = allowsFixtures
    }

    public func live() -> any SafeStorageKeyProviding {
        if allowsFixtures, environment[ImportEnvironment.fixtureHomeKey].map({ !$0.isEmpty }) == true {
            // A fixture home never falls back to the real Keychain.
            return FixtureSafeStorage(environment: environment, fileManager: fileManager) ?? FixtureSafeStorage(passwords: [:])
        }
        return KeychainSafeStorage()
    }
}
