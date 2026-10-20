import Foundation
import Testing

@testable import CmuxSettings

/// The control-plane files (socket, markers, password) must resolve **outside**
/// the macOS TCC-protected app-data roots, or the separately-signed `cmux` CLI
/// re-triggers the "access data from other apps" prompt on every agent hook
/// (https://github.com/manaflow-ai/cmux/issues/5146).
@Suite struct CmuxStateDirectoryTests {
    @Test func resolvesUnderLocalStateNotLibrary() {
        let home = URL(fileURLWithPath: "/Users/test-user", isDirectory: true)
        let url = CmuxStateDirectory.url(homeDirectory: home)

        #expect(url.path == "/Users/test-user/.local/state/cmux")
        // The whole point of the fix: never under a TCC-protected app-data root.
        #expect(!url.path.contains("/Library/Application Support"))
        #expect(!url.path.contains("/Library/Containers"))
        #expect(!url.path.contains("/Library/Group Containers"))
    }

    @Test func socketPathStaysWellWithinUnixPathLimit() {
        // sun_path is 104 bytes on macOS; the resolved socket path must fit even
        // for a long home directory.
        let home = URL(
            fileURLWithPath: "/Users/a-fairly-long-account-name-for-testing",
            isDirectory: true
        )
        let socket = CmuxStateDirectory.url(homeDirectory: home)
            .appendingPathComponent("cmux.sock", isDirectory: false)
        #expect(socket.path.utf8.count < 104)
    }

    @Test func legacyApplicationSupportURLPointsAtOldLocation() {
        let legacy = CmuxStateDirectory.legacyApplicationSupportURL(fileManager: .default)
        // Only used for one-time migration; it must still address the old folder.
        #expect(legacy?.lastPathComponent == "cmux")
        #expect(legacy?.path.contains("/Application Support/cmux") == true)
    }
}

/// Migration of the persistent socket password out of the legacy Application
/// Support location into the non-TCC state directory.
@Suite(.serialized) struct SocketControlPasswordMigrationTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pw-migrate-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func movesPasswordWhenDestinationAbsent() throws {
        let legacyDir = tempDir()
        let destDir = tempDir()
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        let destination = destDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("hunter2".utf8).write(to: legacy)

        let moved = SocketControlPasswordStore.migratePasswordFile(from: legacy, to: destination, fileManager: .default)

        #expect(moved)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "hunter2")
        // Migrated file is owner-only.
        let perms = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func preservesExistingDestination() throws {
        let legacyDir = tempDir()
        let destDir = tempDir()
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        let destination = destDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("old".utf8).write(to: legacy)
        try Data("current".utf8).write(to: destination)

        let moved = SocketControlPasswordStore.migratePasswordFile(from: legacy, to: destination, fileManager: .default)

        #expect(!moved)
        // The newer destination wins; the legacy file is left untouched.
        #expect(try String(contentsOf: destination, encoding: .utf8) == "current")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func noOpWhenLegacyMissing() {
        let legacyDir = tempDir()
        let destDir = tempDir()
        defer { try? FileManager.default.removeItem(at: destDir) }
        let legacy = legacyDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        let destination = destDir.appendingPathComponent(SocketControlPasswordStore.fileName)

        #expect(!SocketControlPasswordStore.migratePasswordFile(from: legacy, to: destination, fileManager: .default))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// When an atomic move fails (e.g. cross-device) but the copy succeeds, the
    /// legacy original is removed so no stale credential copy is left behind in the
    /// TCC-protected directory (https://github.com/manaflow-ai/cmux/issues/5146).
    @Test func copyFallbackRemovesLegacyAfterSuccessfulCopy() throws {
        let legacyDir = tempDir()
        let destDir = tempDir()
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        let destination = destDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("hunter2".utf8).write(to: legacy)

        // Force the move to fail so the copy fallback runs.
        let moved = SocketControlPasswordStore.migratePasswordFile(
            from: legacy,
            to: destination,
            fileManager: MoveFailingFileManager()
        )

        #expect(moved)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "hunter2")
        // The legacy original must not linger in the protected directory.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    /// After migration, a store reading the default state-directory location sees
    /// the password that previously lived in Application Support.
    @Test func migratedPasswordIsReadableByStore() throws {
        let legacyDir = tempDir()
        let destDir = tempDir()
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        let destination = destDir.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("secret-pw".utf8).write(to: legacy)

        SocketControlPasswordStore.migratePasswordFile(from: legacy, to: destination, fileManager: .default)

        let store = SocketControlPasswordStore(environment: [:], fileURL: destination)
        #expect(try store.loadPassword() == "secret-pw")
        #expect(store.verify(password: "secret-pw"))
    }
}

/// A `FileManager` whose `moveItem(at:to:)` always fails, used to exercise the
/// copy fallback path of ``SocketControlPasswordStore/migratePasswordFile(from:to:fileManager:)``.
///
/// Holds no mutable state, so it is safe to mark `@unchecked Sendable`.
private final class MoveFailingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
