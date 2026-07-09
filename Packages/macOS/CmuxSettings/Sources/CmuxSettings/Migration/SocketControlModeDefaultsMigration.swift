import Foundation

/// One-time launch migration that normalizes the persisted control-socket mode
/// and (for release builds) ports the legacy keychain password into the current
/// storage layout.
///
/// Two independent steps run in sequence at the very start of launch:
///
/// 1. **Socket mode normalization.** The persisted ``SocketControlSettings/appStorageKey``
///    value is mapped through ``SocketControlSettings/migrateMode(_:)`` and rewritten
///    only when the canonical raw value differs from what is stored (collapsing legacy
///    and old-format mode strings to the current enum). When that key is absent but the
///    pre-enum boolean ``SocketControlSettings/legacyEnabledKey`` exists, it is translated
///    to ``SocketControlMode/cmuxOnly`` (enabled) or ``SocketControlMode/off`` (disabled).
///
/// 2. **Keychain password migration.** Skipped for debug-like and staging bundle
///    identifiers: each tagged build has a unique bundle id with its own `UserDefaults`
///    domain, so migration would run on every launch and trigger a macOS keychain access
///    prompt (the legacy keychain item was created by a differently-signed app). For all
///    other bundle identifiers, ``SocketControlPasswordStore/migrateLegacyKeychainPasswordIfNeeded(defaults:)``
///    runs against the injected defaults.
///
/// Wire format is **frozen**: the `UserDefaults` keys, the mode raw values, and the
/// bundle-identifier gating are kept byte-identical to the logic when it lived inline in
/// `cmuxApp.init()`. `UserDefaults` and the bundle identifier are injected so the behavior
/// is fully unit-testable against a scoped suite. App-side launch instrumentation (e.g.
/// breadcrumb logging) stays in the app: ``migrate(willMigrateKeychainPassword:didMigrateKeychainPassword:)``
/// invokes the supplied hooks around the keychain step exactly when it runs, with no-op
/// defaults so the package stays free of app dependencies.
///
/// ```swift
/// SocketControlModeDefaultsMigration(
///     defaults: .standard,
///     bundleIdentifier: Bundle.main.bundleIdentifier
/// ).migrate()
/// ```
public struct SocketControlModeDefaultsMigration: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let bundleIdentifier: String?

    /// Creates a migration operating on the given defaults suite and bundle identifier.
    /// - Parameters:
    ///   - defaults: The `UserDefaults` suite to read and rewrite.
    ///   - bundleIdentifier: The running build's bundle identifier, which gates the
    ///     keychain password migration step (`Bundle.main.bundleIdentifier` in the app).
    public init(defaults: UserDefaults, bundleIdentifier: String?) {
        self.defaults = defaults
        self.bundleIdentifier = bundleIdentifier
    }

    /// Normalizes the persisted socket mode, then runs the legacy keychain password
    /// migration unless the bundle identifier is debug-like or staging.
    ///
    /// - Parameters:
    ///   - willMigrateKeychainPassword: Invoked immediately before the keychain
    ///     migration runs (only when the bundle identifier is eligible).
    ///   - didMigrateKeychainPassword: Invoked immediately after the keychain
    ///     migration runs (only when the bundle identifier is eligible).
    public func migrate(
        willMigrateKeychainPassword: () -> Void = {},
        didMigrateKeychainPassword: () -> Void = {}
    ) {
        // Migrate legacy and old-format socket mode values to the new enum.
        if let stored = defaults.string(forKey: SocketControlSettings.appStorageKey) {
            let migrated = SocketControlSettings.migrateMode(stored)
            if migrated.rawValue != stored {
                defaults.set(migrated.rawValue, forKey: SocketControlSettings.appStorageKey)
            }
        } else if let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.cmuxOnly.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }

        // Skip keychain migration for DEV/staging builds. Each tagged build gets a
        // unique bundle ID with its own UserDefaults domain, so migration would run
        // on every launch and trigger a macOS keychain access prompt (the legacy
        // keychain item was created by a differently-signed app).
        if !SocketControlSettings.isDebugLikeBundleIdentifier(bundleIdentifier)
            && !SocketControlSettings.isStagingBundleIdentifier(bundleIdentifier) {
            willMigrateKeychainPassword()
            SocketControlPasswordStore().migrateLegacyKeychainPasswordIfNeeded(defaults: defaults)
            didMigrateKeychainPassword()
        }
    }
}
