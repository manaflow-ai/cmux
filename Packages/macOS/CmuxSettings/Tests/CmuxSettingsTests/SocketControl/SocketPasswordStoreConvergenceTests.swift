import CmuxSettings
import Foundation
import Testing


/// Guards the socket-password convergence: the Settings UI persists the password
/// through ``SecretFileStore`` (the catalog's `automation.socketPassword`
/// ``SecretFileKey``), while the socket listener reads it through
/// ``SocketControlPasswordStore``. These must resolve to the **same on-disk
/// file**, or the user could set a password in Settings that the listener never
/// sees (or vice versa) — the exact "configure in one place, not read in
/// another" regression this convergence exists to remove.
///
/// All collaborators are pointed at a temp directory, so these run hermetically
/// without touching the real Application Support, keychain, or `cmux.json`.
@Suite struct SocketPasswordStoreConvergenceTests {
    private let secretKey = SettingCatalog().automation.socketPassword

    /// A throwaway control directory standing in for ``CmuxStateDirectory``.
    private func tempBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-convergence-\(UUID().uuidString)", isDirectory: true)
    }

    /// The single most important invariant: the two stores address the same file
    /// name. If either constant drifts, this fails before anything ships.
    @Test func catalogSecretKeyFileNameMatchesPasswordStore() {
        #expect(secretKey.fileName == SocketControlPasswordStore.fileName)
        #expect(secretKey.id == "automation.socketPassword")
    }

    /// Writing through the Settings path (``SecretFileStore``) is readable by the
    /// listener path (``SocketControlPasswordStore``) at the same base directory.
    @Test func settingsWriteIsVisibleToListener() async throws {
        let base = tempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let secretStore = SecretFileStore(baseDirectory: base)
        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: base.appendingPathComponent(SocketControlPasswordStore.fileName, isDirectory: false)
        )

        try await secretStore.set("hunter2", for: secretKey)

        #expect(try passwordStore.loadPassword() == "hunter2")
        #expect(passwordStore.verify(password: "hunter2"))
        #expect(passwordStore.hasConfiguredPassword())
    }

    /// Writing through the listener path is visible to the Settings path. This is
    /// the channel the managed-config bridge and the legacy `saveSocketPassword`
    /// call site use, so the Settings UI must observe it.
    @Test func listenerWriteIsVisibleToSettings() async throws {
        let base = tempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: base.appendingPathComponent(SocketControlPasswordStore.fileName, isDirectory: false)
        )
        let secretStore = SecretFileStore(baseDirectory: base)

        try passwordStore.savePassword("fromListener")

        #expect(try await secretStore.value(for: secretKey) == "fromListener")
        #expect(await secretStore.hasValue(for: secretKey))
    }

    /// The exact file URLs computed by each store are byte-for-byte equal when the
    /// secret store's base directory is derived the way the app derives it — from
    /// the password file's parent directory. This mirrors `cmuxApp.init`, which
    /// sets `secretBaseDirectory = defaultPasswordFileURL().deletingLastPathComponent()`.
    /// It catches drift in the control-directory layout between the two stores,
    /// which a "both end in the same name" check would miss.
    @Test func bothStoresResolveIdenticalFileURL() async throws {
        let controlDirectory = tempBaseDirectory()
        let passwordURL = try #require(
            SocketControlPasswordStore.defaultPasswordFileURL(directory: controlDirectory, fileManager: .default)
        )
        // Exactly the derivation cmuxApp.init performs.
        let secretBase = passwordURL.deletingLastPathComponent()
        let secretURL = SecretFileStore(baseDirectory: secretBase).fileURL(for: secretKey)
        #expect(passwordURL.standardizedFileURL == secretURL.standardizedFileURL)
    }

    /// Clearing via Settings clears what the listener sees, with no stale file.
    @Test func settingsResetClearsListenerValue() async throws {
        let base = tempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let secretStore = SecretFileStore(baseDirectory: base)
        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: base.appendingPathComponent(SocketControlPasswordStore.fileName, isDirectory: false)
        )

        try await secretStore.set("temp", for: secretKey)
        #expect(passwordStore.hasConfiguredPassword())

        try await secretStore.reset(secretKey)
        #expect(try passwordStore.loadPassword() == nil)
        #expect(!passwordStore.hasConfiguredPassword())
    }
}
