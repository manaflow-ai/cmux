internal import CMUXAgentLaunch
public import Foundation

/// Reads, validates, searches, and caches cmux-managed Amp thread history.
///
/// The actor is the single mutable owner of the bounded source cache. Callers
/// inject one repository at their composition root and share it across initial
/// loading, directory snapshots, and paginated searches.
public actor AmpHookSessionRepository: AmpHookSessionReading {
    private struct SourceFingerprint: Equatable, Sendable {
        let modificationDate: Date
        let fileSize: UInt64
    }

    private struct CachedSource: Sendable {
        let fingerprint: SourceFingerprint
        let snapshots: [AmpHookSessionSnapshot]
    }

    // Justification: Foundation documents FileManager's methods as thread-safe,
    // and actor isolation serializes every access to this injected instance.
    private nonisolated(unsafe) let fileManager: FileManager
    private let sourceCacheCapacity: Int
    private var cachedSources: [URL: CachedSource] = [:]
    private var sourceLRU: [URL] = []

    /// Creates an Amp hook-session repository.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem dependency used for metadata and file reads.
    ///   - sourceCacheCapacity: Maximum number of source files retained in the LRU cache.
    public init(
        fileManager: FileManager = .default,
        sourceCacheCapacity: Int = 8
    ) {
        self.fileManager = fileManager
        self.sourceCacheCapacity = max(1, sourceCacheCapacity)
    }

    /// Returns validated Amp thread snapshots matching a query and directory filter.
    ///
    /// A missing store is an empty history. An existing store that cannot be
    /// read or decoded throws ``AmpHookSessionRepositoryError/unreadableStore``.
    /// Cached sources are refreshed when either their modification time or byte
    /// size changes.
    ///
    /// - Parameters:
    ///   - sourceURL: Location of the cmux-managed Amp hook-session store.
    ///   - query: Case-insensitive text matched against thread id, title, and cwd.
    ///   - workingDirectory: Optional normalized exact-directory filter.
    ///   - offset: Number of matching snapshots to skip.
    ///   - limit: Maximum number of matching snapshots to return.
    /// - Returns: A page sorted by latest activity descending, then thread id.
    /// - Throws: ``AmpHookSessionRepositoryError/unreadableStore`` when an existing store cannot be read.
    public func snapshots(
        at sourceURL: URL,
        matching query: String,
        workingDirectory: String?,
        offset: Int,
        limit: Int
    ) async throws -> [AmpHookSessionSnapshot] {
        guard offset >= 0, limit > 0 else { return [] }
        let sourceURL = sourceURL.standardizedFileURL
        let allSnapshots = try snapshots(at: sourceURL)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let directoryFilter = Self.normalizedWorkingDirectory(workingDirectory)
        let filtered = allSnapshots.lazy.filter { snapshot in
            if let directoryFilter, snapshot.workingDirectory != directoryFilter {
                return false
            }
            guard !needle.isEmpty else { return true }
            let haystack = [
                snapshot.sessionID,
                snapshot.title ?? "",
                snapshot.workingDirectory ?? "",
            ].joined(separator: " ").lowercased()
            return haystack.range(of: needle, options: [.literal]) != nil
        }
        return Array(filtered.dropFirst(offset).prefix(limit))
    }

    private func snapshots(at sourceURL: URL) throws -> [AmpHookSessionSnapshot] {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            removeCachedSource(sourceURL)
            return []
        }
        let fingerprint = try sourceFingerprint(at: sourceURL)
        if let cached = cachedSources[sourceURL], cached.fingerprint == fingerprint {
            touchSource(sourceURL)
            return cached.snapshots
        }
        guard let data = fileManager.contents(atPath: sourceURL.path),
              let store = try? JSONDecoder().decode(AmpHookSessionStoreFile.self, from: data) else {
            removeCachedSource(sourceURL)
            throw AmpHookSessionRepositoryError.unreadableStore
        }
        let snapshots = Self.validatedSnapshots(from: store)
        cache(CachedSource(fingerprint: fingerprint, snapshots: snapshots), at: sourceURL)
        return snapshots
    }

    private func sourceFingerprint(at sourceURL: URL) throws -> SourceFingerprint {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw AmpHookSessionRepositoryError.unreadableStore
        }
        return SourceFingerprint(modificationDate: modificationDate, fileSize: fileSize)
    }

    private func cache(_ source: CachedSource, at sourceURL: URL) {
        if cachedSources[sourceURL] == nil,
           cachedSources.count >= sourceCacheCapacity,
           let leastRecentlyUsed = sourceLRU.first {
            cachedSources.removeValue(forKey: leastRecentlyUsed)
            sourceLRU.removeFirst()
        }
        cachedSources[sourceURL] = source
        touchSource(sourceURL)
    }

    private func touchSource(_ sourceURL: URL) {
        sourceLRU.removeAll { $0 == sourceURL }
        sourceLRU.append(sourceURL)
    }

    private func removeCachedSource(_ sourceURL: URL) {
        cachedSources.removeValue(forKey: sourceURL)
        sourceLRU.removeAll { $0 == sourceURL }
    }

    private static func validatedSnapshots(
        from store: AmpHookSessionStoreFile
    ) -> [AmpHookSessionSnapshot] {
        var snapshots: [AmpHookSessionSnapshot] = []
        snapshots.reserveCapacity(store.sessions.count)
        for (key, record) in store.sessions {
            let sessionID = (record.sessionId ?? key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentRestoreLaunch(kind: "amp", sessionID: sessionID) != nil else {
                continue
            }
            let launchCommand = trustedLaunchCommand(record.launchCommand)
            let workingDirectory = normalizedWorkingDirectory(
                record.cwd ?? launchCommand?.workingDirectory
            )
            snapshots.append(AmpHookSessionSnapshot(
                sessionID: sessionID,
                title: normalizedText(record.title),
                workingDirectory: workingDirectory,
                launchCommand: launchCommand,
                modified: Date(timeIntervalSince1970: record.updatedAt ?? record.startedAt ?? 0)
            ))
        }
        return snapshots.sorted { lhs, rhs in
            lhs.modified == rhs.modified
                ? lhs.sessionID < rhs.sessionID
                : lhs.modified > rhs.modified
        }
    }

    private static func trustedLaunchCommand(
        _ launchCommand: AgentLaunchCommand?
    ) -> AgentLaunchCommand? {
        guard let launchCommand,
              !launchCommand.arguments.isEmpty,
              AgentLaunchCaptureTrust.launcherDescribesKind(
                  launchCommand.launcher,
                  kind: "amp"
              ),
              AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                  processName: launchCommand.executablePath,
                  arguments: launchCommand.arguments,
                  kind: "amp"
              ),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    private static func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let value = normalizedText(value) else { return nil }
        var normalized = ((value as NSString).expandingTildeInPath as NSString).standardizingPath
        if normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
