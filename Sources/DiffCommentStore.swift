import CmuxWorkspaces
import CryptoKit
import Foundation

/// A review comment left on a line range in the diff viewer.
///
/// `endLine` (on `side`) is the anchor line the comment renders under;
/// `lineText` is that line's content at save time so the comment can be
/// re-anchored when the same diff is regenerated with shifted line numbers.
struct DiffComment: Codable, Equatable, Identifiable {
    var id: UUID
    var filePath: String
    var side: String
    var startLine: Int
    var endLine: Int
    var endSide: String?
    var lineText: String
    var message: String
    /// Formatted text block appended to a TextBox submission when the
    /// workspace's pending pool is consumed.
    var submissionText: String?
    /// Set when a TextBox submission delivered this comment to an agent;
    /// consumed comments never re-enter the pending pool.
    var consumedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

/// Persists diff viewer review comments per git repository, one JSON file per
/// repo (keyed by a hash of the canonical repo root path) under
/// `Application Support/cmux/diff-comments/`. Comments outlive individual
/// `cmux diff` invocations, so a regenerated diff for the same repo shows the
/// same comments.
@MainActor
final class DiffCommentStore {
    static let shared = DiffCommentStore()

    private struct RepoCommentsFile: Codable {
        var repoRoot: String
        var comments: [DiffComment]
    }

    private let directoryURL: URL?
    private var cacheByRepoKey: [String: RepoCommentsFile] = [:]

    init(directoryURL: URL? = DiffCommentStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func comments(repoRoot: String) -> [DiffComment] {
        loadFile(repoRoot: repoRoot).comments
    }

    @discardableResult
    func upsert(_ comment: DiffComment, repoRoot: String) -> DiffComment {
        var file = loadFile(repoRoot: repoRoot)
        var stored = comment
        if let index = file.comments.firstIndex(where: { $0.id == comment.id }) {
            stored.createdAt = file.comments[index].createdAt
            file.comments[index] = stored
        } else {
            file.comments.append(stored)
        }
        saveFile(file, repoRoot: repoRoot)
        return stored
    }

    /// Marks comments as delivered to an agent so they never re-enter the
    /// pending submission pool.
    func markConsumed(ids: [UUID], repoRoot: String, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var file = loadFile(repoRoot: repoRoot)
        let idSet = Set(ids)
        var changed = false
        for index in file.comments.indices where idSet.contains(file.comments[index].id) {
            file.comments[index].consumedAt = date
            changed = true
        }
        if changed {
            saveFile(file, repoRoot: repoRoot)
        }
    }

    @discardableResult
    func delete(id: UUID, repoRoot: String) -> Bool {
        var file = loadFile(repoRoot: repoRoot)
        let countBefore = file.comments.count
        file.comments.removeAll { $0.id == id }
        guard file.comments.count != countBefore else { return false }
        saveFile(file, repoRoot: repoRoot)
        return true
    }

    private func loadFile(repoRoot: String) -> RepoCommentsFile {
        let key = Self.repoKey(forRepoRoot: repoRoot)
        if let cached = cacheByRepoKey[key] {
            return cached
        }
        let empty = RepoCommentsFile(repoRoot: Self.canonicalRepoRoot(repoRoot), comments: [])
        guard let fileURL = fileURL(forRepoKey: key),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder().decode(RepoCommentsFile.self, from: data) else {
            cacheByRepoKey[key] = empty
            return empty
        }
        cacheByRepoKey[key] = decoded
        return decoded
    }

    private func saveFile(_ file: RepoCommentsFile, repoRoot: String) {
        let key = Self.repoKey(forRepoRoot: repoRoot)
        cacheByRepoKey[key] = file
        guard let fileURL = fileURL(forRepoKey: key) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
#if DEBUG
            cmuxDebugLog("diffComments.store.saveFailed error=\(error.localizedDescription)")
#endif
        }
    }

    private func fileURL(forRepoKey key: String) -> URL? {
        directoryURL?.appendingPathComponent("\(key).json", isDirectory: false)
    }

    nonisolated static func canonicalRepoRoot(_ raw: String) -> String {
        URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func repoKey(forRepoRoot repoRoot: String) -> String {
        let canonical = canonicalRepoRoot(repoRoot)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).lowercased()
    }

    nonisolated static func defaultDirectoryURL(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy().isRunningUnderAutomatedTests
    ) -> URL? {
        guard !isRunningUnderAutomatedTests, let appSupportDirectory else { return nil }
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-comments", isDirectory: true)
    }

    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
