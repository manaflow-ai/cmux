import CryptoKit
import Foundation

/// Persists the diff viewer's per-file "Viewed" review state natively, next to
/// `DiffViewerPreferencesStore`, because generated viewer origins do not
/// reliably keep web storage.
///
/// One JSON file per scope (repository root + diff source identity) under
/// `~/Library/Application Support/cmux/diff-viewer/viewed/`. Each entry keeps
/// the fingerprint of the file's patch at the time it was marked viewed; the
/// webview compares it against the current patch and shows "changed since
/// viewed" on a mismatch (GitHub behavior). The store is bounded: at most
/// `maxEntriesPerScope` entries per scope and `maxScopes` scope files, oldest
/// first. Reads are synchronous from an in-memory cache; file writes run on a
/// serial background queue so the bridge reply never blocks the main thread.
final class DiffViewerViewedFilesStore: @unchecked Sendable {
    static let shared = DiffViewerViewedFilesStore()

    static let maxEntriesPerScope = 2_000
    static let maxScopes = 64

    struct Scope: Hashable, Sendable {
        var repoRoot: String
        var source: String
    }

    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var fingerprint: String
        var viewedAt: Date
    }

    private struct ScopeFile: Codable, Sendable {
        var repoRoot: String
        var source: String
        var files: [Entry]
    }

    private let lock = NSLock()
    private let directoryURL: URL?
    private let persistenceQueue: DispatchQueue
    private var cacheByKey: [String: ScopeFile] = [:]

    init(
        directoryURL: URL? = DiffViewerViewedFilesStore.defaultDirectoryURL(),
        persistenceQueue: DispatchQueue = DispatchQueue(label: "com.cmux.diff-viewer.viewed-files", qos: .utility)
    ) {
        self.directoryURL = directoryURL
        self.persistenceQueue = persistenceQueue
    }

    /// Nil under automated tests so suites never touch the user's files.
    nonisolated static func defaultDirectoryURL(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests, let appSupportDirectory else { return nil }
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
            .appendingPathComponent("viewed", isDirectory: true)
    }

    func entries(scope: Scope) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(scope).files
    }

    /// Bridge shape: `[{ path, fingerprint }]`.
    func jsonEntries(scope: Scope) -> [[String: Any]] {
        entries(scope: scope).map { ["path": $0.path, "fingerprint": $0.fingerprint] }
    }

    @discardableResult
    func markViewed(scope: Scope, path: String, fingerprint: String, at date: Date = Date()) -> Entry {
        let entry = Entry(path: path, fingerprint: fingerprint, viewedAt: date)
        lock.lock()
        defer { lock.unlock() }
        var file = loadLocked(scope)
        file.files.removeAll { $0.path == path }
        file.files.append(entry)
        if file.files.count > Self.maxEntriesPerScope {
            file.files.sort { $0.viewedAt < $1.viewedAt }
            file.files.removeFirst(file.files.count - Self.maxEntriesPerScope)
        }
        storeLocked(file, scope: scope)
        return entry
    }

    @discardableResult
    func clear(scope: Scope, path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var file = loadLocked(scope)
        let countBefore = file.files.count
        file.files.removeAll { $0.path == path }
        guard file.files.count != countBefore else { return false }
        storeLocked(file, scope: scope)
        return true
    }

    /// Blocks until every queued write has finished. Tests only.
    func waitForPendingWrites() {
        persistenceQueue.sync {}
    }

    nonisolated static func scopeKey(_ scope: Scope) -> String {
        let canonical = DiffCommentStore.canonicalRepoRoot(scope.repoRoot) + "\n" + scope.source
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).lowercased()
    }

    private func loadLocked(_ scope: Scope) -> ScopeFile {
        let key = Self.scopeKey(scope)
        if let cached = cacheByKey[key] {
            return cached
        }
        let empty = ScopeFile(repoRoot: DiffCommentStore.canonicalRepoRoot(scope.repoRoot), source: scope.source, files: [])
        guard let fileURL = fileURL(forKey: key),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder().decode(ScopeFile.self, from: data) else {
            cacheByKey[key] = empty
            return empty
        }
        cacheByKey[key] = decoded
        return decoded
    }

    private func storeLocked(_ file: ScopeFile, scope: Scope) {
        let key = Self.scopeKey(scope)
        cacheByKey[key] = file
        guard let directoryURL, let fileURL = fileURL(forKey: key) else { return }
        let snapshot = file
        persistenceQueue.async {
            Self.write(snapshot, to: fileURL, in: directoryURL)
        }
    }

    private static func write(_ file: ScopeFile, to fileURL: URL, in directoryURL: URL) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
            pruneScopeFiles(in: directoryURL, keeping: fileURL)
        } catch {
#if DEBUG
            cmuxDebugLog("diffViewer.viewedFiles.saveFailed error=\(error.localizedDescription)")
#endif
        }
    }

    /// Evicts the least recently written scope files beyond `maxScopes`.
    private static func pruneScopeFiles(in directoryURL: URL, keeping keptURL: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let scopeFiles = urls.filter { $0.pathExtension == "json" }
        guard scopeFiles.count > maxScopes else { return }
        let dated = scopeFiles.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, url == keptURL ? Date.distantFuture : date)
        }
        let victims = dated.sorted { $0.1 < $1.1 }.prefix(scopeFiles.count - maxScopes)
        for (url, _) in victims {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(forKey key: String) -> URL? {
        directoryURL?.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
