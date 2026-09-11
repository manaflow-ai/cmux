import Foundation
import Security

/// Persists non-secret speech preferences and a service-scoped MiniMax Keychain credential.
///
/// Inject a dedicated defaults suite and Keychain service for isolated environments.
/// The saved credential is never stored in defaults or synchronized through iCloud.
///
/// ```swift
/// let preferences = ReadAloudPreferences(
///     defaults: appDefaults,
///     keychainService: "com.example.cmux.read-aloud"
/// )
/// try await preferences.save(configuration: ReadAloudConfiguration())
/// ```
public actor ReadAloudPreferences {
    private let defaults: UserDefaults
    private let keychainService: String
    private let configurationKey = "readAloud.configuration"
    private let consentKey = "readAloud.cloudConsent"

    /// Creates a preferences store without reading the saved credential.
    /// - Parameters:
    ///   - defaults: The caller-owned store for configuration and consent only.
    ///   - keychainService: A nonempty service identifier scoped to the calling app or test.
    public init(defaults: UserDefaults, keychainService: String) {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    /// Returns saved speech preferences, or defaults if the saved representation is invalid.
    /// - Returns: A supported configuration with a nonempty voice and speed from 0.5 through 2.
    public func configuration() -> ReadAloudConfiguration {
        guard let data = defaults.data(forKey: configurationKey),
              let configuration = try? JSONDecoder().decode(ReadAloudConfiguration.self, from: data),
              (try? validate(configuration)) != nil else {
            return ReadAloudConfiguration()
        }
        return configuration
    }

    /// Saves validated non-secret speech preferences without altering consent or the credential.
    /// - Parameter configuration: Turbo or HD speech-2.8 settings with a nonempty voice and finite speed in 0.5...2.
    /// - Throws: A localized validation error or a configuration encoding error.
    public func save(configuration: ReadAloudConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: configurationKey)
    }

    /// Reads the MiniMax credential for a synthesis request, never for display in settings.
    /// - Returns: The saved key, or `nil` only when no item exists.
    /// - Throws: A localized error retaining the Keychain status, or an invalid-credential error.
    public func apiKey() throws -> String? {
        var query = try credentialQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReadAloudPreferencesError.keychain(status) }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadAloudPreferencesError.invalidCredential
        }
        return key
    }

    /// Stores a new or replacement MiniMax key without deleting the existing key first.
    /// - Parameter key: A nonempty key; surrounding whitespace and newlines are removed.
    /// - Throws: A localized validation or Keychain error; an unsuccessful update leaves the old item intact.
    public func saveAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ReadAloudPreferencesError.emptyCredential }
        let query = try credentialQuery()
        let data = Data(trimmedKey.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ReadAloudPreferencesError.keychain(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw ReadAloudPreferencesError.keychain(insertStatus) }
    }

    /// Explicitly removes the service-scoped credential; a missing item is already removed.
    /// - Throws: A localized error if the Keychain refuses the removal.
    public func removeAPIKey() throws {
        let query = try credentialQuery()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReadAloudPreferencesError.keychain(status)
        }
    }

    /// Returns whether the user explicitly opted in to sending selected text to MiniMax.
    /// - Returns: `false` until consent has been recorded in the injected defaults store.
    public func consentGranted() -> Bool {
        defaults.bool(forKey: consentKey)
    }

    /// Records an explicit user consent choice independently of credential and speech settings.
    /// - Parameter granted: Whether sending selected text to MiniMax is allowed.
    public func setConsentGranted(_ granted: Bool) {
        defaults.set(granted, forKey: consentKey)
    }

    /// Queries item existence without retrieving credential data into settings state.
    func hasAPIKey() throws -> Bool {
        var query = try credentialQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw ReadAloudPreferencesError.keychain(status) }
        return true
    }

    private func credentialQuery() throws -> [String: Any] {
        guard !keychainService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadAloudPreferencesError.invalidService
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "minimax-api-key",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

}
