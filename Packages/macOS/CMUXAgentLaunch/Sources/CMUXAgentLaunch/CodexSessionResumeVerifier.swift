import Foundation
import SQLite3

/// Evidence owned by Codex that a session identifier can be passed to `codex resume`.
public struct CodexSessionResumeEvidence: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case threadIndex
        case legacyRollout
    }

    /// The user-owned thread that should be passed to `codex resume`.
    public let sessionId: String
    public let rolloutPath: String
    public let source: Source
}

/// Verifies Codex resume identifiers against Codex's thread index or a legacy rollout.
public struct CodexSessionResumeVerifier: Sendable {
    private let indexCache = CodexThreadIndexCache()

    public init() {}

    /// Returns evidence only when Codex owns a non-empty user-restorable rollout
    /// for `sessionId`.
    ///
    /// Modern Codex sessions must be present in `state_5.sqlite`. The rollout fallback
    /// preserves sessions created by older Codex versions, but requires the rollout's
    /// `session_meta` record to contain the exact identifier. Indexed subagents resolve
    /// through Codex-owned parent metadata to their interactive root. Automation threads
    /// and unresolvable child chains are rejected.
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

        if let evidence = indexedEvidence(
            requestedSessionId: sessionId,
            databasePath: databasePath,
            fileManager: fileManager
        ) {
            return evidence
        }
        // An indexed thread that fails ownership checks must not regain authority
        // through the less-specific legacy transcript fallback.
        if indexCache.threads(
            databasePath: databasePath,
            fileManager: fileManager
        )[sessionId] != nil {
            return nil
        }

        guard let transcriptPath = normalized(transcriptPath).map({ ($0 as NSString).expandingTildeInPath }),
              let metadata = sessionMetadata(atPath: transcriptPath, fileManager: fileManager),
              metadata.sessionId == sessionId,
              !metadata.isSubagent,
              !metadata.isAutomation,
              !metadata.isExec else {
            return nil
        }
        return CodexSessionResumeEvidence(
            sessionId: sessionId,
            rolloutPath: transcriptPath,
            source: .legacyRollout
        )
    }

    private func indexedEvidence(
        requestedSessionId: String,
        databasePath: String,
        fileManager: FileManager
    ) -> CodexSessionResumeEvidence? {
        let threads = indexCache.threads(
            databasePath: databasePath,
            fileManager: fileManager
        )
        var currentSessionId = requestedSessionId
        var visited: Set<String> = []

        for _ in 0..<32 {
            guard visited.insert(currentSessionId).inserted,
                  let thread = threads[currentSessionId],
                  regularNonEmptyFileExists(
                      atPath: thread.rolloutPath,
                      fileManager: fileManager
                  ) else {
                return nil
            }

            let metadata = sessionMetadata(
                atPath: thread.rolloutPath,
                fileManager: fileManager
            )
            if let metadataSessionId = metadata?.sessionId,
               metadataSessionId != currentSessionId {
                return nil
            }

            let threadSource = normalized(thread.threadSource)?.lowercased()
            if threadSource == "automation" ||
                metadata?.isAutomation == true ||
                metadata?.isExec == true {
                return nil
            }

            let isSubagent = threadSource == "subagent" || metadata?.isSubagent == true
            if isSubagent {
                guard let parentSessionId = metadata?.parentSessionId,
                      parentSessionId != currentSessionId else {
                    return nil
                }
                currentSessionId = parentSessionId
                continue
            }

            guard threadSource == nil || threadSource == "user" else {
                return nil
            }
            return CodexSessionResumeEvidence(
                sessionId: currentSessionId,
                rolloutPath: thread.rolloutPath,
                source: .threadIndex
            )
        }
        return nil
    }

    private struct IndexedThread: Sendable {
        let rolloutPath: String
        let threadSource: String?
    }

    private struct SessionMetadata {
        let sessionId: String
        let parentSessionId: String?
        let isSubagent: Bool
        let isAutomation: Bool
        let isExec: Bool
    }

    private final class CodexThreadIndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var threadsByDatabase: [String: [String: IndexedThread]] = [:]

        func threads(
            databasePath: String,
            fileManager: FileManager
        ) -> [String: IndexedThread] {
            lock.lock()
            if let cached = threadsByDatabase[databasePath] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let loaded = loadThreads(databasePath: databasePath, fileManager: fileManager)
            lock.lock()
            let threads = threadsByDatabase[databasePath] ?? loaded
            threadsByDatabase[databasePath] = threads
            lock.unlock()
            return threads
        }

        private func loadThreads(
            databasePath: String,
            fileManager: FileManager
        ) -> [String: IndexedThread] {
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
            var readsThreadSource = true
            if sqlite3_prepare_v2(
                database,
                "SELECT id, rollout_path, thread_source FROM threads",
                -1,
                &statement,
                nil
            ) != SQLITE_OK {
                sqlite3_finalize(statement)
                statement = nil
                readsThreadSource = false
                guard sqlite3_prepare_v2(
                    database,
                    "SELECT id, rollout_path FROM threads",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK else {
                    sqlite3_finalize(statement)
                    return [:]
                }
            }
            guard let statement else { return [:] }
            defer { sqlite3_finalize(statement) }

            var threads: [String: IndexedThread] = [:]
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
                let threadSource: String?
                if readsThreadSource, let sourceBytes = sqlite3_column_text(statement, 2) {
                    let value = String(cString: sourceBytes)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    threadSource = value.isEmpty ? nil : value
                } else {
                    threadSource = nil
                }
                threads[sessionId] = IndexedThread(
                    rolloutPath: rolloutPath,
                    threadSource: threadSource
                )
            }
            return threads
        }
    }

    private func sessionMetadata(
        atPath path: String,
        fileManager: FileManager
    ) -> SessionMetadata? {
        guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        let prefix = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \Character.isNewline).prefix(32) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let sessionId = normalized(payload["id"] as? String) else {
                continue
            }
            let source = payload["source"]
            let sourceIsSubagent = sourceContainsKind("subagent", value: source)
            let sourceKind = normalized(source as? String)?.lowercased()
            let originator = normalized(payload["originator"] as? String)?.lowercased()
            let parentSessionId = normalized(payload["parent_thread_id"] as? String)
                ?? normalized(payload["forked_from_id"] as? String)
                ?? nestedNormalizedString(forKey: "parent_thread_id", value: source)
                ?? (sourceIsSubagent
                    ? normalized(payload["session_id"] as? String)
                    : nil)
            return SessionMetadata(
                sessionId: sessionId,
                parentSessionId: parentSessionId,
                isSubagent: sourceIsSubagent,
                isAutomation: sourceContainsKind("automation", value: source),
                isExec: sourceKind == "exec" || originator == "codex_exec"
            )
        }
        return nil
    }

    private func sourceContainsKind(_ kind: String, value: Any?) -> Bool {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(kind) == .orderedSame
        }
        if let value = value as? [String: Any] {
            return value.contains { key, child in
                if key.caseInsensitiveCompare(kind) == .orderedSame {
                    return true
                }
                guard child is [String: Any] || child is [Any] else {
                    return false
                }
                return sourceContainsKind(kind, value: child)
            }
        }
        if let value = value as? [Any] {
            return value.contains { sourceContainsKind(kind, value: $0) }
        }
        return false
    }

    private func nestedNormalizedString(forKey targetKey: String, value: Any?) -> String? {
        if let value = value as? [String: Any] {
            for (key, child) in value {
                if key == targetKey, let result = normalized(child as? String) {
                    return result
                }
                if let result = nestedNormalizedString(forKey: targetKey, value: child) {
                    return result
                }
            }
        } else if let value = value as? [Any] {
            for child in value {
                if let result = nestedNormalizedString(forKey: targetKey, value: child) {
                    return result
                }
            }
        }
        return nil
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
