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
/// It can also read other installs' snapshots (import, never writing them),
/// export the saved snapshot to a file, and keep a newer-schema snapshot as a
/// side file before this build would overwrite it.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every method is
/// synchronous because its callers are: `applicationWillTerminate` must
/// complete the save before returning, and the autosave path already hops to
/// a private serial queue app-side. There is no mutable state to protect.
public struct SessionSnapshotRepository<SnapshotValue: SessionSnapshotRepresenting>: SessionSnapshotStoring {
    private let schemaVersion: Int
    private let bundleIdentifier: String?
    private let appSupportDirectory: URL?
    private let decoderUserInfo: [CodingUserInfoKey: Bool]
    private let historyLimit: Int
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
    ///   - decoderUserInfo: Trust or migration flags applied only while decoding snapshots.
    ///   - historyLimit: How many archived snapshots to keep in the rotated
    ///     history directory (the richest one is always kept on top of the
    ///     newest ones; see ``SessionSnapshotHistoryEntry``).
    public init(
        schemaVersion: Int,
        bundleIdentifier: String?,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        decoderUserInfo: [CodingUserInfoKey: Bool] = [:],
        historyLimit: Int = 10
    ) {
        self.historyLimit = max(1, historyLimit)
        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
        self.decoderUserInfo = decoderUserInfo
    }

    public func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<SnapshotValue> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unusable }
        guard let snapshot = decodedSnapshot(from: data) else { return .unusable }
        guard snapshot.version == schemaVersion else { return .unusable }
        guard snapshot.hasWindows else { return .unusable }
        return .loaded(snapshot)
    }

    private func decodedSnapshot(from data: Data) -> SnapshotValue? {
        let decoder = JSONDecoder()
        for (key, value) in decoderUserInfo {
            decoder.userInfo[key] = value
        }
        return try? SessionSnapshotCodingStack().run {
            try decoder.decode(SnapshotValue.self, from: data)
        }
    }

    /// Only the top-level `version` of a snapshot, so a file written by a
    /// different schema can be classified without decoding its payload.
    private struct SchemaVersionProbe: Decodable {
        let version: Int
    }

    private func probedSchemaVersion(of data: Data) -> Int? {
        try? SessionSnapshotCodingStack().run {
            try JSONDecoder().decode(SchemaVersionProbe.self, from: data).version
        }
    }

    // MARK: - Moving snapshots between installs

    public func snapshotFileURL(bundleIdentifier: String) -> URL? {
        fileLocation().primaryFileURL(
            bundleIdentifier: bundleIdentifier
        )
    }

    public func importableSnapshot(
        fileURL: URL
    ) -> Result<SessionSnapshotImport<SnapshotValue>, SessionSnapshotImportError> {
        if isOwnPrimarySnapshot(fileURL) {
            return .failure(.liveSnapshot(fileURL))
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .failure(.fileNotFound(fileURL))
        }
        switch Self.readRegularFile(atPath: fileURL.path, maximumBytes: Self.maximumImportableSnapshotBytes) {
        case .data(let data):
            return importableSnapshot(data: data, fileURL: fileURL)
        case .notRegularOrTooLarge:
            return .failure(.notASessionSnapshot(fileURL))
        case .unreadable:
            return .failure(.unreadable(fileURL))
        }
    }

    private enum BoundedFileRead {
        case data(Data)
        case notRegularOrTooLarge
        case unreadable
    }

    /// Reads a regular file of at most `maximumBytes`. A FIFO or device node
    /// would block the reader forever and an unbounded file would be read
    /// whole into memory, so the file is opened non-blocking and its type
    /// and size are checked on the same descriptor that is read (no window
    /// for a symlink to be re-pointed between the check and the read).
    private static func readRegularFile(atPath path: String, maximumBytes: Int64) -> BoundedFileRead {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return .unreadable }
        guard (status.st_mode & S_IFMT) == S_IFREG, Int64(status.st_size) <= maximumBytes else {
            return .notRegularOrTooLarge
        }
        guard let data = try? handle.readToEnd() else { return .unreadable }
        return .data(data)
    }

    /// Upper bound on a snapshot file accepted for import. Real snapshots
    /// (scrollback included) are a few MiB at most.
    static var maximumImportableSnapshotBytes: Int64 { 256 * 1024 * 1024 }

    private func importableSnapshot(
        data: Data,
        fileURL: URL
    ) -> Result<SessionSnapshotImport<SnapshotValue>, SessionSnapshotImportError> {
        guard let version = probedSchemaVersion(of: data) else {
            return .failure(.notASessionSnapshot(fileURL))
        }
        if version > schemaVersion {
            return .failure(.newerSchemaVersion(fileURL, found: version, supported: schemaVersion))
        }
        if version < schemaVersion {
            return .failure(.olderSchemaVersion(fileURL, found: version, supported: schemaVersion))
        }
        guard let snapshot = decodedSnapshot(from: data), snapshot.version == schemaVersion else {
            return .failure(.notASessionSnapshot(fileURL))
        }
        guard snapshot.hasWindows else {
            return .failure(.noWindows(fileURL))
        }
        return .success(SessionSnapshotImport(snapshot: snapshot, fileURL: fileURL))
    }

    public func importableSnapshot(
        bundleIdentifier: String
    ) -> Result<SessionSnapshotImport<SnapshotValue>, SessionSnapshotImportError> {
        let appSupport = resolvedAppSupportDirectory()
        let primaryURL = SessionSnapshotFileLocation(appSupportDirectory: appSupport).primaryFileURL(
            bundleIdentifier: bundleIdentifier
        )
        if isOwnPrimarySnapshot(primaryURL) {
            // Importing this install into itself would reopen the windows it
            // already shows; its previous launch is `restore-session`.
            return .failure(.liveSnapshot(primaryURL))
        }
        let primaryError: SessionSnapshotImportError
        switch importableSnapshot(fileURL: primaryURL) {
        case .success(let imported):
            return .success(imported)
        case .failure(let error):
            primaryError = error
        }
        // Same fallback as startup restore: the `-previous` backup is the
        // recovery copy when the primary is missing or cannot be restored.
        let backupURL = SessionSnapshotFileLocation(appSupportDirectory: appSupport).backupFileURL(
            bundleIdentifier: bundleIdentifier
        )
        switch importableSnapshot(fileURL: backupURL) {
        case .success(let imported):
            return .success(imported)
        case .failure(let backupError):
            if case .fileNotFound = primaryError {
                if case .fileNotFound = backupError {
                    return .failure(primaryError)
                }
                return .failure(backupError)
            }
            return .failure(primaryError)
        }
    }

    private func isOwnPrimarySnapshot(_ fileURL: URL) -> Bool {
        guard let ownPrimary = defaultSnapshotFileURL() else { return false }
        return Self.sameFile(ownPrimary, fileURL)
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func exportSnapshot(to destination: URL, overwrite: Bool) -> Result<URL, SessionSnapshotExportError> {
        let destination = destination.standardizedFileURL
        let ownFiles = [defaultSnapshotFileURL(), manualRestoreSnapshotFileURL()].compactMap { $0 }
        if ownFiles.contains(where: { Self.sameFile($0, destination) }) {
            return .failure(.destinationIsLiveSnapshot(destination))
        }
        if !overwrite && itemExists(at: destination) {
            return .failure(.destinationExists(destination))
        }
        for sourceURL in [defaultSnapshotFileURL(), manualRestoreSnapshotFileURL()].compactMap({ $0 }) {
            // Copy the validated bytes rather than re-encoding them, so the
            // export is exactly what this install would restore from.
            guard let data = try? Data(contentsOf: sourceURL),
                  case .success = importableSnapshot(data: data, fileURL: sourceURL) else {
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                // Without overwrite, create the file exclusively (O_EXCL) so
                // a file that appears after the check above is never replaced.
                try data.write(to: destination, options: overwrite ? .atomic : .withoutOverwriting)
                // The export carries scrollback and working directories;
                // keep it private to the user like the live snapshot.
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return .success(sourceURL)
            } catch {
                if !overwrite && itemExists(at: destination) {
                    return .failure(.destinationExists(destination))
                }
                return .failure(.writeFailed(destination))
            }
        }
        return .failure(.noSnapshot)
    }

    /// Whether anything, including a dangling symlink, occupies `url`.
    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private enum NewerSchemaPreservation {
        case notNeeded
        case preserved(URL)
        case failed
    }

    private func preserveNewerSchemaSnapshotOutcome(fileURL: URL) -> NewerSchemaPreservation {
        guard let data = try? Data(contentsOf: fileURL),
              let version = probedSchemaVersion(of: data),
              version > schemaVersion else {
            return .notNeeded
        }
        let sideURL = SessionSnapshotFileLocation.newerSchemaSideFileURL(
            for: fileURL,
            schemaVersion: version
        )
        if let existing = try? Data(contentsOf: sideURL), existing == data {
            return .preserved(sideURL)
        }
        do {
            try data.write(to: sideURL, options: .atomic)
        } catch {
            return .failed
        }
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "session.snapshot.newerSchemaPreserved version=\(version) path=\(sideURL.path)"
        )
#endif
        return .preserved(sideURL)
    }

    @discardableResult
    public func preserveNewerSchemaSnapshot(fileURL: URL) -> URL? {
        guard case .preserved(let url) = preserveNewerSchemaSnapshotOutcome(fileURL: fileURL) else {
            return nil
        }
        return url
    }

    public func preserveNewerSchemaSnapshotBeforeReplacing(fileURL: URL) -> Bool {
        switch preserveNewerSchemaSnapshotOutcome(fileURL: fileURL) {
        case .notNeeded, .preserved:
            return true
        case .failed:
            return false
        }
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
        return try SessionSnapshotCodingStack().run { try encoder.encode(snapshot) }
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
            // Replacing the manual-restore cache must never destroy the only
            // copy written by a newer cmux. Preserve that backup first; if the
            // side-file write fails, keep the backup untouched and retry on a
            // later sync instead of overwriting recoverable data.
            switch preserveNewerSchemaSnapshotOutcome(fileURL: backupURL) {
            case .notNeeded, .preserved:
                _ = save(snapshot, fileURL: backupURL)
            case .failed:
                break
            }
        case .missing:
            switch preserveNewerSchemaSnapshotOutcome(fileURL: backupURL) {
            case .notNeeded, .preserved:
                removeSnapshot(fileURL: backupURL)
            case .failed:
                // The backup may be the only copy a newer build can read.
                // Keep it when copying to the schema side file fails.
                break
            }
        case .unusable:
            // The primary snapshot exists but cannot be restored. Keep the
            // backup: it is the only remaining recovery path for the user's
            // sessions (startup fallback and `cmux restore-session`). A
            // primary written by a newer schema is copied aside first, since
            // the next autosave replaces it.
            preserveNewerSchemaSnapshot(fileURL: primaryURL)
            preserveNewerSchemaSnapshot(fileURL: backupURL)
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

    @discardableResult
    public func archiveSnapshotToHistory(
        fileURL: URL,
        richness: SessionSnapshotRichness,
        archivedAt: Date
    ) -> SessionSnapshotHistoryEntry? {
        guard let directory = historyDirectoryURL(),
              fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let existing = historyEntries()
        if let newest = existing.first, fileSize(newest.fileURL) == fileSize(fileURL),
           fileManager.contentsEqual(atPath: newest.fileURL.path, andPath: fileURL.path) {
            return nil
        }
        let entry = SessionSnapshotHistoryEntry(
            fileURL: directory.appendingPathComponent(
                SessionSnapshotHistoryEntry.fileName(
                    safeBundleId: safeBundleIdentifier(),
                    archivedAt: archivedAt,
                    richness: richness
                ),
                isDirectory: false
            ),
            archivedAt: archivedAt,
            richness: richness
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            // copyItem clones on APFS, so launch pays no read+write of a
            // multi-megabyte scrollback snapshot.
            try fileManager.copyItem(at: fileURL, to: entry.fileURL)
        } catch {
            return nil
        }
        let all = [entry] + existing
        let kept = Set(SessionSnapshotHistoryEntry.retained(all, limit: historyLimit).map(\.fileURL))
        for stale in all where !kept.contains(stale.fileURL) {
            try? fileManager.removeItem(at: stale.fileURL)
        }
        return kept.contains(entry.fileURL) ? entry : nil
    }

    private func fileSize(_ url: URL) -> UInt64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    public func historyEntries() -> [SessionSnapshotHistoryEntry] {
        // Names, not URLs: enumerated URLs can come back symlink-resolved
        // (`/private/var`) and would not match the URLs archive returns.
        guard let directory = historyDirectoryURL(),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let safeBundleId = safeBundleIdentifier()
        return names
            .compactMap {
                SessionSnapshotHistoryEntry.parse(
                    fileURL: directory.appendingPathComponent($0, isDirectory: false),
                    safeBundleId: safeBundleId
                )
            }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    /// `Application Support/cmux/session-history/`, shared by every bundle;
    /// file names carry the bundle identifier.
    public func historyDirectoryURL() -> URL? {
        cmuxAppSupportDirectoryURL()?.appendingPathComponent("session-history", isDirectory: true)
    }

    private func snapshotFileURL(suffix: String) -> URL? {
        fileLocation().fileURL(bundleIdentifier: bundleIdentifier, suffix: suffix)
    }

    private func cmuxAppSupportDirectoryURL() -> URL? {
        fileLocation().cmuxDirectoryURL
    }

    private func safeBundleIdentifier() -> String {
        SessionSnapshotFileLocation.safeBundleIdentifier(bundleIdentifier)
    }

    private func fileLocation() -> SessionSnapshotFileLocation {
        SessionSnapshotFileLocation(appSupportDirectory: resolvedAppSupportDirectory())
    }

    private func resolvedAppSupportDirectory() -> URL {
        appSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
