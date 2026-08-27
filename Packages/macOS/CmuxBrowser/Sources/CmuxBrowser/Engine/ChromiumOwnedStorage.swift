@preconcurrency import Foundation

/// Resolves the cmux-owned filesystem namespace used by managed Chromium.
///
/// The runtime artifact cache and every pane profile intentionally share this
/// resolver. Keeping the bundle namespace in one value prevents a future
/// bundle-id change from leaving profiles and the executable in unrelated
/// directories, and it never consults a system Chrome location.
struct ChromiumOwnedStorage: Sendable {
    // FileManager is documented thread-safe. The escape hatch is scoped to
    // this immutable dependency instead of making the resolver unchecked.
    nonisolated(unsafe) let fileManager: FileManager
    let applicationSupportURLProvider: @Sendable () -> URL?
    let bundleIdentifierProvider: @Sendable () -> String

    /// Returns cmux's namespaced application-support directory.
    func applicationDirectory() throws -> URL {
        guard let supportURL = applicationSupportURLProvider() else {
            throw ChromiumOwnedStorageError.applicationSupportUnavailable
        }
        let directory = supportURL.appendingPathComponent(
            safePathComponent(bundleIdentifierProvider()),
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Returns the directory containing downloaded Chromium runtime revisions.
    func runtimeDirectory() throws -> URL {
        let directory = try applicationDirectory().appendingPathComponent(
            "ChromiumRuntime",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Returns one persistent profile directory for a cmux browser profile.
    ///
    /// A storage identity is supplied by the out-of-process fallback, where
    /// Chromium places an exclusive lock on each user-data directory. Those
    /// pane sessions are intentionally isolated; the in-process CEF adapter
    /// omits the identity and pools one request context per logical profile so
    /// its panes share cookies and local storage.
    /// Omitting the identity resolves the stable profile root used by CEF and
    /// by cleanup/migration callers.
    func profileDirectory(
        for profileID: UUID,
        storageID: UUID? = nil
    ) throws -> URL {
        let directory = try profileDirectoryURL(for: profileID, storageID: storageID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Resolves a profile directory without creating its leaf directory.
    ///
    /// Cleanup callers use this form so clearing an unknown profile never
    /// creates a new profile tree merely to remove it.
    func profileDirectoryURL(
        for profileID: UUID,
        storageID: UUID? = nil
    ) throws -> URL {
        var directory = try applicationDirectory()
            .appendingPathComponent("ChromiumProfiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        if let storageID {
            directory = directory
                .appendingPathComponent("Panes", isDirectory: true)
                .appendingPathComponent(storageID.uuidString.lowercased(), isDirectory: true)
        }
        return directory
    }

    private func safePathComponent(_ value: String) -> String {
        let filtered = value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        }
        let result = String(filtered)
        return result.isEmpty ? "com.cmuxterm.app" : result
    }
}
