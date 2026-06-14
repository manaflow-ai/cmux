public import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// File-backed store for the app session snapshot.
///
/// Faithful lift of the legacy `SessionPersistenceStore` namespace enum from
/// `Sources/SessionPersistence.swift`: JSON encode/decode (sorted keys),
/// atomic writes with identical-content skip, the primary/`-previous` backup
/// pair under `Application Support/cmux/`, and the unusable-primary recovery
/// path are unchanged. The legacy per-call `bundleIdentifier`/
/// `appSupportDirectory`/`FileManager` defaulted parameters became
/// constructor-injected state (they were constant per process), and the
/// schema version the legacy code read from `SessionSnapshotSchema` is
/// injected as `schemaVersion`.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every method is
/// synchronous because its callers are: `applicationWillTerminate` must
/// complete the save before returning, and the autosave path already hops to
/// a private serial queue app-side. There is no mutable state to protect.
public struct SessionSnapshotRepository<SnapshotValue: SessionSnapshotRepresenting>: SessionSnapshotStoring {
    private let schemaVersion: Int
    private let bundleIdentifier: String?
    private let appSupportDirectory: URL?
    // Justification: FileManager is documented thread-safe ("the methods of
    // the shared FileManager object can be called from multiple threads
    // safely") but Foundation does not mark it Sendable.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a repository.
    ///
    /// - Parameters:
    ///   - schemaVersion: The current snapshot schema version; persisted
    ///     snapshots with any other version are unusable.
    ///   - bundleIdentifier: The bundle identifier used to derive the
    ///     snapshot file name (pass `Bundle.main.bundleIdentifier` at the
    ///     composition root). Falls back to `com.cmuxterm.app` when nil or
    ///     blank.
    ///   - appSupportDirectory: Overrides the discovered user Application
    ///     Support directory (tests pass a temporary directory).
    ///   - fileManager: File system access, injected for testability.
    public init(
        schemaVersion: Int,
        bundleIdentifier: String?,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
    }

    public func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<SnapshotValue> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unusable }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(SnapshotValue.self, from: data) else { return .unusable }
        guard snapshot.version == schemaVersion else { return .unusable }
        guard snapshot.hasWindows else { return .unusable }
        return .loaded(snapshot)
    }

    public func load(fileURL: URL? = nil) -> SnapshotValue? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard case .loaded(let snapshot) = loadOutcome(fileURL: fileURL) else { return nil }
        return snapshot
    }

    @discardableResult
    public func save(_ snapshot: SnapshotValue, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func encodedSnapshotData(_ snapshot: SnapshotValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    public func loadReopenSessionSnapshot(fileURL: URL? = nil) -> SnapshotValue? {
        guard let fileURL = fileURL ?? manualRestoreSnapshotFileURL() else {
            return nil
        }
        return load(fileURL: fileURL)
    }

    public func syncManualRestoreSnapshotCache() {
        guard let backupURL = manualRestoreSnapshotFileURL() else { return }
        guard let primaryURL = defaultSnapshotFileURL() else { return }
        switch loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            _ = save(snapshot, fileURL: backupURL)
        case .missing:
            removeSnapshot(fileURL: backupURL)
        case .unusable:
            // The primary snapshot exists but cannot be restored. Keep the
            // backup: it is the only remaining recovery path for the user's
            // sessions (startup fallback and `cmux restore-session`).
            break
        }
    }

    public func loadStartupSnapshot() -> SnapshotValue? {
        guard let primaryURL = defaultSnapshotFileURL() else { return nil }
        switch loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            return snapshot
        case .missing:
            return nil
        case .unusable:
            let backup = loadReopenSessionSnapshot(fileURL: nil)
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "session.restore.primaryUnusable path=\(primaryURL.path) " +
                    "backupRecovered=\(backup != nil ? 1 : 0)"
            )
#endif
            return backup
        }
    }

    public func defaultSnapshotFileURL() -> URL? {
        snapshotFileURL(suffix: "")
    }

    public func manualRestoreSnapshotFileURL() -> URL? {
        snapshotFileURL(suffix: "-previous")
    }

    private func snapshotFileURL(suffix: String) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("session-\(safeBundleId)\(suffix).json", isDirectory: false)
    }
}
