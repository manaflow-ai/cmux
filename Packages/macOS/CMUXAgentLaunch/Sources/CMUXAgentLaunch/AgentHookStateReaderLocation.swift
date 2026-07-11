import Foundation

/// Prepares the bundle-scoped hook state directory used by app-side readers.
///
/// Stable and Nightly copy pre-scoping hook stores once, then read only the
/// scoped directory. Tagged debug builds never import the shared legacy store.
public struct AgentHookStateReaderLocation {
    /// The sole directory app-side readers should consult.
    public let directoryURL: URL

    /// Resolves the reader directory and performs the one-time legacy migration.
    public init(
        environment: [String: String],
        applicationSupportDirectory: URL?,
        bundleIdentifier: String?,
        legacyHomeDirectory: URL,
        fileManager: FileManager
    ) {
        directoryURL = AgentHookStateLocation.resolveDirectoryURL(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            legacyHomeDirectory: legacyHomeDirectory
        )

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
            return
        }

        try? migrateLegacyStores(
            from: legacyHomeDirectory.appendingPathComponent(".cmuxterm", isDirectory: true),
            fileManager: fileManager
        )
    }

    private func migrateLegacyStores(from legacyDirectory: URL, fileManager: FileManager) throws {
        guard legacyDirectory.standardizedFileURL != directoryURL.standardizedFileURL else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
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
                let destination = directoryURL.appendingPathComponent(source.lastPathComponent, isDirectory: false)
                if fileManager.fileExists(atPath: destination.path) {
                    try mergeMissingSessions(from: source, into: destination, fileManager: fileManager)
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
            }
        }

        try Data().write(to: marker, options: .atomic)
    }

    private func mergeMissingSessions(from source: URL, into destination: URL, fileManager: FileManager) throws {
        guard let sourceData = fileManager.contents(atPath: source.path),
              let sourceRoot = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            return
        }
        guard let destinationData = fileManager.contents(atPath: destination.path),
              var destinationRoot = try? JSONSerialization.jsonObject(with: destinationData) as? [String: Any] else {
            throw NSError(domain: "AgentHookStateMigration", code: 1)
        }

        let sourceSessions = sessionEntries(in: sourceRoot)
        var destinationSessions = sessionEntries(in: destinationRoot)
        var changed = false
        for (sessionID, record) in sourceSessions where destinationSessions[sessionID] == nil {
            destinationSessions[sessionID] = record
            changed = true
        }
        guard changed else { return }

        if destinationRoot["sessions"] is [String: Any] {
            destinationRoot["sessions"] = destinationSessions
        } else {
            for (sessionID, record) in destinationSessions {
                destinationRoot[sessionID] = record
            }
        }
        let mergedData = try JSONSerialization.data(withJSONObject: destinationRoot, options: [.sortedKeys])
        try mergedData.write(to: destination, options: .atomic)
    }

    private func sessionEntries(in root: [String: Any]) -> [String: Any] {
        if let nested = root["sessions"] as? [String: Any] {
            return nested
        }
        return root.filter { $0.value is [String: Any] }
    }
}
