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

    public init?(environment: [String: String]) {
        guard let home = environment[ImportEnvironment.fixtureHomeKey], !home.isEmpty,
              let path = environment[Self.environmentKey], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        self.passwords = passwords
    }

    public func password(service: String) throws(CookieImportError) -> Data {
        guard let password = passwords[service] else { throw .keyNotFound(service: service) }
        return Data(password.utf8)
    }
}

/// The key provider for this process: the fixture file in a fixture-home
/// test launch, else the login Keychain.
public enum SafeStorageKeys {
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> any SafeStorageKeyProviding {
        if environment[ImportEnvironment.fixtureHomeKey].map({ !$0.isEmpty }) == true {
            // A fixture home never falls back to the real Keychain.
            return FixtureSafeStorage(environment: environment) ?? FixtureSafeStorage(passwords: [:])
        }
        return KeychainSafeStorage()
    }
}
