public import Foundation

/// Ensures password-mode configurations have a usable socket credential.
///
/// Older cmux versions accepted `socketControlMode=password` even when the
/// password setting was absent. Once enforcement became active, those existing
/// configurations could no longer authenticate the bundled CLI. This migration
/// creates a credential in the canonical secure store exactly once when the
/// persisted mode requires one and no credential is available.
///
/// The migration is synchronous and all side effects are injected, so the app
/// composition root can run it before starting the listener and package tests
/// can exercise the upgrade contract without touching a user's state directory.
public struct SocketControlPasswordMigration {
    /// The UserDefaults key that records completion of this migration.
    public static let migrationDefaultsKey = "socketControlPasswordConfigurationMigrationVersion"
    /// The current migration version.
    public static let migrationVersion = 1

    /// The result of one migration attempt.
    public enum Outcome: Equatable, Sendable {
        /// The persisted socket mode does not require a password.
        case notNeeded
        /// A credential was already present and the migration was recorded.
        case alreadyConfigured
        /// This migration version was already completed.
        case alreadyMigrated
        /// A new credential was generated and persisted.
        case generated
        /// Credential generation or persistence failed; a later launch may retry.
        case failed
    }

    private let defaults: UserDefaults
    private let passwordStore: SocketControlPasswordStore
    private let generatePassword: @Sendable () -> String

    /// Creates a migration with injectable defaults, password storage, and generator.
    ///
    /// The default generator uses the system random-number source and emits a
    /// base64url-safe value without whitespace, suitable for the line-oriented
    /// socket authentication protocol.
    public init(
        defaults: UserDefaults = .standard,
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        generatePassword: (@Sendable () -> String)? = nil
    ) {
        self.defaults = defaults
        self.passwordStore = passwordStore
        self.generatePassword = generatePassword ?? Self.makeSecurePassword
    }

    /// Generates and persists a password when `configuredMode` is `.password`
    /// and the canonical password store is empty.
    ///
    /// A successful migration records its version before returning. Clearing the
    /// credential later is therefore respected rather than silently replaced on
    /// every subsequent launch.
    @discardableResult
    public func migrateIfNeeded(configuredMode: SocketControlMode) -> Outcome {
        guard configuredMode == .password else {
            return .notNeeded
        }
        guard defaults.integer(forKey: Self.migrationDefaultsKey) < Self.migrationVersion else {
            return .alreadyMigrated
        }

        if passwordStore.hasConfiguredPassword() {
            defaults.set(Self.migrationVersion, forKey: Self.migrationDefaultsKey)
            return .alreadyConfigured
        }

        let password = generatePassword().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            return .failed
        }

        do {
            try passwordStore.savePassword(password)
        } catch {
            return .failed
        }
        defaults.set(Self.migrationVersion, forKey: Self.migrationDefaultsKey)
        return .generated
    }

    private static func makeSecurePassword() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
