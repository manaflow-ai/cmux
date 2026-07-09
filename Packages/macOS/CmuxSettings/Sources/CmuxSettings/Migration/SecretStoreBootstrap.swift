public import Foundation

/// Sequences the secure secret-store bootstrap that runs once at app launch,
/// before any managed-config layer reads `cmux.json`.
///
/// The composition root (the `@main` App initializer) names the concrete
/// `FileManager.default` and the resolved `cmux.json` URL and injects them, then
/// calls ``configureSecretStore()`` to:
///
/// 1. relocate a pre-existing socket-control password out of the legacy
///    Application Support directory into the non-protected cmux state directory
///    (the CLI reads this file on every agent hook, and a cross-identity reach
///    into Application Support triggers the macOS Sequoia "access data from other
///    apps" prompt, https://github.com/manaflow-ai/cmux/issues/5146);
/// 2. derive the secret base directory (the same directory, and
///    `socket-control-password` file, the socket auth path reads via
///    ``SocketControlPasswordStore``, so the Settings UI and the listener share
///    one source of truth);
/// 3. construct the ``SecretFileStore`` rooted there;
/// 4. lift any plaintext socket-control password out of `cmux.json` into the
///    secure store via ``PlaintextSecretMigration`` and scrub it from the config.
///
/// Running before the managed-config layer (`CmuxSettingsFileStore`, loaded later
/// during launch) reads the file means removing the plaintext key can never be
/// misread as a removed managed override that would trigger a restore. All
/// side-effecting dependencies are injected, so the sequence is deterministic in
/// tests.
public struct SecretStoreBootstrap {
    private let fileManager: FileManager
    private let configFileURL: URL

    /// Creates a bootstrap rooted at the injected file system and config file.
    /// - Parameters:
    ///   - fileManager: The file manager used for the legacy relocation, the
    ///     secret base directory resolution, and the secret store; composition
    ///     roots pass `.default`.
    ///   - configFileURL: The resolved `cmux.json` location whose plaintext key is
    ///     lifted and scrubbed.
    public init(fileManager: FileManager, configFileURL: URL) {
        self.fileManager = fileManager
        self.configFileURL = configFileURL
    }

    /// Runs the launch-time secret bootstrap and returns the configured store.
    ///
    /// - Returns: The ``SecretFileStore`` the Settings UI and the socket listener
    ///   both read.
    @discardableResult
    public func configureSecretStore() -> SecretFileStore {
        // Relocate a pre-existing socket password out of the legacy Application
        // Support directory before any store reads it. The app owns its
        // Application Support data, so it can perform this move silently.
        SocketControlPasswordStore.migrateLegacyApplicationSupportPasswordFileIfNeeded(fileManager: fileManager)

        // Secrets live in their own 0600 files under the cmux state directory, the
        // same directory (and `socket-control-password` file) the socket auth path
        // reads via SocketControlPasswordStore, so the Settings UI and the listener
        // share one source of truth.
        let secretBaseDirectory = SocketControlPasswordStore.defaultPasswordFileURL(fileManager: fileManager)?
            .deletingLastPathComponent()
            ?? CmuxStateDirectory.url(homeDirectory: fileManager.homeDirectoryForCurrentUser)
        let secretStore = SecretFileStore(baseDirectory: secretBaseDirectory)

        // Lift any plaintext socket-control password out of `cmux.json` into the
        // secure store, then scrub it from the config. This runs before the
        // managed-config layer reads the file, so removing the key can never be
        // misread as a removed managed override that would trigger a restore. The
        // secure file the migration writes is the same one both the Settings UI
        // (via `secretStore`) and the socket listener (via
        // `SocketControlPasswordStore`) read.
        let socketPasswordStore = SocketControlPasswordStore()
        let secretMigrationTimestamp: String = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            return formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
        }()
        PlaintextSecretMigration.scrub(
            plaintextKeyPath: ["automation", "socketPassword"],
            configURL: configFileURL,
            loadCurrentSecret: { (try? socketPasswordStore.loadPassword()) ?? nil },
            saveSecret: { try socketPasswordStore.savePassword($0) },
            backupTimestamp: secretMigrationTimestamp
        )
        return secretStore
    }
}
