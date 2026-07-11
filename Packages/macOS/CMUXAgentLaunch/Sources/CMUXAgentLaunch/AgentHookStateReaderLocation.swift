import Darwin
import Foundation

/// Resolves and reads the bundle-scoped hook state used by app-side readers.
///
/// Stable and Nightly expose a scoped-preferred compatibility view until a
/// background migration completes. Tagged debug builds never consult the
/// shared legacy store.
public struct AgentHookStateReaderLocation: Sendable {
    /// The sole directory app-side readers should watch for new hook writes.
    public let directoryURL: URL

    private let legacyDirectoryURL: URL?
    private let migrationMarkerURL: URL?

    /// Resolves the reader directory without blocking on migration work.
    public init(
        environment: [String: String],
        applicationSupportDirectory: URL?,
        bundleIdentifier: String?,
        legacyHomeDirectory: URL,
        fileManager _: FileManager
    ) {
        directoryURL = AgentHookStateLocation(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            legacyHomeDirectory: legacyHomeDirectory
        ).directoryURL

        let override = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard override?.isEmpty != false,
              bundleIdentifier == "com.cmuxterm.app" || bundleIdentifier == "com.cmuxterm.app.nightly",
              let applicationSupportDirectory,
              let bundleLocation = AgentHookStateLocation(
                  applicationSupportDirectory: applicationSupportDirectory,
                  bundleIdentifier: bundleIdentifier
              ),
              directoryURL.standardizedFileURL == bundleLocation.directoryURL.standardizedFileURL else {
            legacyDirectoryURL = nil
            migrationMarkerURL = nil
            return
        }

        let legacyDirectory = legacyHomeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true)
        guard legacyDirectory.standardizedFileURL != directoryURL.standardizedFileURL else {
            legacyDirectoryURL = nil
            migrationMarkerURL = nil
            return
        }
        legacyDirectoryURL = legacyDirectory
        migrationMarkerURL = directoryURL
            .appendingPathComponent(".legacy-hook-state-migrated-v1", isDirectory: false)
    }

    /// Returns one store's scoped-preferred compatibility snapshot.
    ///
    /// Before migration completes, the returned JSON merges missing legacy
    /// sessions and routing records in memory. This keeps one-shot readers
    /// correct without waiting for hook-writer or migration locks; hook writers
    /// publish each complete store snapshot with an atomic rename.
    public func storeData(named filename: String, fileManager: FileManager) -> Data? {
        guard filename.hasSuffix("-hook-sessions.json"),
              filename == URL(fileURLWithPath: filename).lastPathComponent else {
            return nil
        }
        let scopedStore = directoryURL.appendingPathComponent(filename, isDirectory: false)
        guard let legacyDirectoryURL, let migrationMarkerURL else {
            return regularStoreData(at: scopedStore, fileManager: fileManager)
        }
        guard !fileManager.fileExists(atPath: migrationMarkerURL.path) else {
            return regularStoreData(at: scopedStore, fileManager: fileManager)
        }
        let scopedData = regularStoreData(at: scopedStore, fileManager: fileManager)
        let legacyData = regularStoreData(
            at: legacyDirectoryURL.appendingPathComponent(filename, isDirectory: false),
            fileManager: fileManager
        )
        return mergedStoreData(scopedData: scopedData, legacyData: legacyData)
    }

    /// Best-effort durable compaction for a background loader.
    ///
    /// Busy locks leave the marker absent so later background reloads retry;
    /// compatibility reads remain complete while migration is pending.
    public func migrateLegacyStoresIfNeeded(fileManager: FileManager) {
        guard let legacyDirectoryURL else { return }
        try? migrateLegacyStores(from: legacyDirectoryURL, fileManager: fileManager)
    }

    private func migrateLegacyStores(from legacyDirectory: URL, fileManager: FileManager) throws {
        let directoryPermissions = NSNumber(value: Int16(0o700))
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directoryURL.path)
        let lock = directoryURL.appendingPathComponent(".legacy-hook-state-migration.lock", isDirectory: false)
        try withExclusiveFileLock(at: lock) {
            let marker = directoryURL.appendingPathComponent(".legacy-hook-state-migrated-v1", isDirectory: false)
            guard !fileManager.fileExists(atPath: marker.path) else { return }

            if fileManager.fileExists(atPath: legacyDirectory.path) {
                let candidates = try fileManager.contentsOfDirectory(
                    at: legacyDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                for source in candidates where source.lastPathComponent.hasSuffix("-hook-sessions.json") {
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let sourceLock = URL(fileURLWithPath: source.path + ".lock", isDirectory: false)
                    try withExclusiveFileLock(at: sourceLock) {
                        let sourceRoot = try storeRoot(at: source, fileManager: fileManager)
                        let destination = directoryURL.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                        let destinationLock = URL(fileURLWithPath: destination.path + ".lock", isDirectory: false)
                        try withExclusiveFileLock(at: destinationLock) {
                            if fileManager.fileExists(atPath: destination.path) {
                                try mergeMissingStoreEntries(
                                    sourceRoot: sourceRoot,
                                    into: destination,
                                    fileManager: fileManager
                                )
                            } else {
                                try fileManager.copyItem(at: source, to: destination)
                            }
                            try fileManager.setAttributes(
                                [.posixPermissions: NSNumber(value: Int16(0o600))],
                                ofItemAtPath: destination.path
                            )
                        }
                    }
                }
            }

            try Data().write(to: marker, options: .atomic)
        }
    }

    private func withExclusiveFileLock<T>(at lock: URL, body: () throws -> T) throws -> T {
        let descriptor = lock.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { flock(descriptor, LOCK_UN) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try body()
    }

    private func mergeMissingStoreEntries(
        sourceRoot: [String: Any],
        into destination: URL,
        fileManager: FileManager
    ) throws {
        let destinationRoot = try storeRoot(at: destination, fileManager: fileManager)
        let merge = mergingMissingStoreEntries(sourceRoot: sourceRoot, into: destinationRoot)
        guard merge.changed else { return }
        let mergedData = try JSONSerialization.data(withJSONObject: merge.root, options: [.sortedKeys])
        try mergedData.write(to: destination, options: .atomic)
    }

    private func mergedStoreData(scopedData: Data?, legacyData: Data?) -> Data? {
        let scopedRoot = scopedData.flatMap(storeRoot(from:))
        let legacyRoot = legacyData.flatMap(storeRoot(from:))
        guard let legacyRoot else { return scopedRoot == nil ? nil : scopedData }
        guard let scopedRoot else { return legacyData }
        let merge = mergingMissingStoreEntries(sourceRoot: legacyRoot, into: scopedRoot)
        guard merge.changed else { return scopedData }
        return try? JSONSerialization.data(withJSONObject: merge.root, options: [.sortedKeys])
    }

    private func mergingMissingStoreEntries(
        sourceRoot: [String: Any],
        into destination: [String: Any]
    ) -> (root: [String: Any], changed: Bool) {
        var destinationRoot = destination
        let sourceSessions = sessionEntries(in: sourceRoot)
        var destinationSessions = sessionEntries(in: destinationRoot)
        var changed = false
        for (sessionID, record) in sourceSessions where destinationSessions[sessionID] == nil {
            destinationSessions[sessionID] = record
            changed = true
        }
        if changed {
            if destinationRoot["sessions"] is [String: Any] {
                destinationRoot["sessions"] = destinationSessions
            } else {
                for (sessionID, record) in destinationSessions {
                    destinationRoot[sessionID] = record
                }
            }
        }

        for key in ["activeSessionsByWorkspace", "activeSessionsBySurface"] {
            guard let sourceEntries = sourceRoot[key] as? [String: Any] else { continue }
            var destinationEntries = destinationRoot[key] as? [String: Any] ?? [:]
            var importedEntry = false
            for (identifier, record) in sourceEntries where destinationEntries[identifier] == nil {
                destinationEntries[identifier] = record
                importedEntry = true
            }
            if importedEntry {
                destinationRoot[key] = destinationEntries
                changed = true
            }
        }

        return (destinationRoot, changed)
    }

    private func storeRoot(at url: URL, fileManager: FileManager) throws -> [String: Any] {
        guard let data = fileManager.contents(atPath: url.path) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard let root = storeRoot(from: data) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return root
    }

    private func storeRoot(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func regularStoreData(at url: URL, fileManager: FileManager) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return fileManager.contents(atPath: url.path)
    }

    private func sessionEntries(in root: [String: Any]) -> [String: Any] {
        if let nested = root["sessions"] as? [String: Any] {
            return nested
        }
        return root.filter { $0.value is [String: Any] }
    }
}
