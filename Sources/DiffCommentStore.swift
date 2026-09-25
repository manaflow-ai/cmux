import CmuxDiffComments
import CryptoKit
import Foundation

/// Persists diff viewer review comments per git repository, one JSON file per
/// repo (keyed by a hash of the canonical repo root path) under
/// `Application Support/cmux/diff-comments/`. Comments outlive individual
/// `cmux diff` invocations, so a regenerated diff for the same repo shows the
/// same comments.
@MainActor
final class DiffCommentStore {
    static let shared = DiffCommentStore(eventBus: .shared)

    private struct RepoCommentsFile: Codable {
        var repoRoot: String
        var comments: [DiffComment]
    }

    private let directoryURL: URL?
    private let eventBus: CmuxEventBus?
    private var cacheByRepoKey: [String: RepoCommentsFile] = [:]

    init(
        directoryURL: URL? = DiffCommentStore.defaultDirectoryURL(),
        eventBus: CmuxEventBus? = nil
    ) {
        self.directoryURL = directoryURL
        self.eventBus = eventBus
    }

    func comments(repoRoot: String) -> [DiffComment] {
        loadFile(repoRoot: repoRoot).comments
    }

    @discardableResult
    func upsert(_ comment: DiffComment, repoRoot: String) -> DiffComment {
        var file = loadFile(repoRoot: repoRoot)
        var stored = comment
        let eventName: String
        if let index = file.comments.firstIndex(where: { $0.id == comment.id }) {
            stored.createdAt = file.comments[index].createdAt
            guard stored != file.comments[index] else { return stored }
            file.comments[index] = stored
            eventName = "comment.updated"
        } else {
            file.comments.append(stored)
            eventName = "comment.created"
        }
        saveFile(file, repoRoot: repoRoot)
        publishLifecycleEvent(eventName, comment: stored, repoRoot: file.repoRoot)
        return stored
    }

    /// Marks comments as delivered to an agent so they never re-enter the
    /// pending submission pool.
    func markConsumed(ids: [UUID], repoRoot: String, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var file = loadFile(repoRoot: repoRoot)
        let idSet = Set(ids)
        var consumedComments: [DiffComment] = []
        for index in file.comments.indices where idSet.contains(file.comments[index].id) {
            guard file.comments[index].consumedAt == nil else { continue }
            file.comments[index].consumedAt = date
            consumedComments.append(file.comments[index])
        }
        if !consumedComments.isEmpty {
            saveFile(file, repoRoot: repoRoot)
            for comment in consumedComments {
                publishLifecycleEvent("comment.consumed", comment: comment, repoRoot: file.repoRoot)
            }
        }
    }

    @discardableResult
    func delete(id: UUID, repoRoot: String) -> Bool {
        var file = loadFile(repoRoot: repoRoot)
        guard let index = file.comments.firstIndex(where: { $0.id == id }) else { return false }
        let comment = file.comments.remove(at: index)
        saveFile(file, repoRoot: repoRoot)
        publishLifecycleEvent("comment.deleted", comment: comment, repoRoot: file.repoRoot)
        return true
    }

    private func publishLifecycleEvent(_ name: String, comment: DiffComment, repoRoot: String) {
        guard let eventBus else { return }
        var payload: [String: Any] = [
            "repo_root": repoRoot,
            "comment_id": comment.id.uuidString,
            "file_path": comment.filePath,
            "side": comment.side,
            "start_line": comment.startLine,
            "end_line": comment.endLine,
            "message": NSNull(),
            "message_length": comment.message.count,
            "redacted_fields": ["message"]
        ]
        if let endSide = comment.endSide {
            payload["end_side"] = endSide
        }
        eventBus.publish(
            name: name,
            category: "comment",
            source: "diff-comments",
            payload: payload
        )
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
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
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
