import Foundation
import SQLite3

/// Evidence owned by Codex that a session identifier can be passed to `codex resume`.
public struct CodexSessionResumeEvidence: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case threadIndex
        case legacyRollout
    }

    public let rolloutPath: String
    public let source: Source
}

/// Verifies Codex resume identifiers against Codex's thread index or a legacy rollout.
public struct CodexSessionResumeVerifier: Sendable {
    private let indexCache = CodexThreadIndexCache()

    public init() {}

    /// Returns evidence only when Codex owns a non-empty rollout for `sessionId`.
    ///
    /// Modern Codex sessions must be present in `state_5.sqlite`. The rollout fallback
    /// preserves sessions created by older Codex versions, but requires the rollout's
    /// `session_meta` record to contain the exact identifier.
    public func evidence(
        sessionId: String,
        transcriptPath: String?,
        codexHome: String,
        fileManager: FileManager = .default
    ) -> CodexSessionResumeEvidence? {
        guard let sessionId = normalized(sessionId) else { return nil }
        let expandedCodexHome = (codexHome as NSString).expandingTildeInPath
        let databasePath = URL(fileURLWithPath: expandedCodexHome, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        if let rolloutPath = indexCache.rolloutPath(
            sessionId: sessionId,
            databasePath: databasePath,
            fileManager: fileManager
        ) {
            return CodexSessionResumeEvidence(rolloutPath: rolloutPath, source: .threadIndex)
        }

        guard let transcriptPath = normalized(transcriptPath).map({ ($0 as NSString).expandingTildeInPath }),
              rolloutContainsSessionMetadata(
                  sessionId: sessionId,
                  path: transcriptPath,
                  fileManager: fileManager
              ) else {
            return nil
        }
        return CodexSessionResumeEvidence(rolloutPath: transcriptPath, source: .legacyRollout)
    }

    private final class CodexThreadIndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var rolloutPathsByDatabase: [String: [String: String]] = [:]

        func rolloutPath(
            sessionId: String,
            databasePath: String,
            fileManager: FileManager
        ) -> String? {
            lock.lock()
            if let cached = rolloutPathsByDatabase[databasePath] {
                lock.unlock()
                return cached[sessionId].flatMap {
                    regularNonEmptyFileExists(atPath: $0, fileManager: fileManager) ? $0 : nil
                }
            }
            lock.unlock()

            let loaded = loadRolloutPaths(databasePath: databasePath, fileManager: fileManager)
            lock.lock()
            let paths = rolloutPathsByDatabase[databasePath] ?? loaded
            rolloutPathsByDatabase[databasePath] = paths
            lock.unlock()
            return paths[sessionId].flatMap {
                regularNonEmptyFileExists(atPath: $0, fileManager: fileManager) ? $0 : nil
            }
        }

        private func loadRolloutPaths(
            databasePath: String,
            fileManager: FileManager
        ) -> [String: String] {
            guard fileManager.fileExists(atPath: databasePath) else { return [:] }
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databasePath,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                nil
            ) == SQLITE_OK, let database else {
                sqlite3_close(database)
                return [:]
            }
            defer { sqlite3_close(database) }

            var statement: OpaquePointer?
            let sql = "SELECT id, rollout_path FROM threads"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                sqlite3_finalize(statement)
                return [:]
            }
            defer { sqlite3_finalize(statement) }

            var paths: [String: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idBytes = sqlite3_column_text(statement, 0),
                      let pathBytes = sqlite3_column_text(statement, 1) else {
                    continue
                }
                let sessionId = String(cString: idBytes).trimmingCharacters(in: .whitespacesAndNewlines)
                let rolloutPath = (
                    String(cString: pathBytes).trimmingCharacters(in: .whitespacesAndNewlines) as NSString
                ).expandingTildeInPath
                guard !sessionId.isEmpty, !rolloutPath.isEmpty else { continue }
                paths[sessionId] = rolloutPath
            }
            return paths
        }

        private func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value > 0
        }
    }

    private func rolloutContainsSessionMetadata(
        sessionId: String,
        path: String,
        fileManager: FileManager
    ) -> Bool {
        guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? handle.close() }

        let prefix = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \Character.isNewline).prefix(32) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  payload["id"] as? String == sessionId else {
                continue
            }
            return true
        }
        return false
    }

    private func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
