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

        if let indexedThread = indexedThread(
            sessionId: sessionId,
            databasePath: databasePath,
            fileManager: fileManager
        ) {
            // An indexed thread that fails ownership checks must not regain
            // authority through the less-specific legacy transcript fallback.
            return indexedEvidence(
                requestedSessionId: sessionId,
                initialThread: indexedThread,
                databasePath: databasePath,
                fileManager: fileManager
            )
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
        initialThread: IndexedThread,
        databasePath: String,
        fileManager: FileManager
    ) -> CodexSessionResumeEvidence? {
        var currentSessionId = requestedSessionId
        var currentThread = initialThread
        var visited: Set<String> = []

        for _ in 0..<32 {
            guard visited.insert(currentSessionId).inserted,
                  regularNonEmptyFileExists(
                      atPath: currentThread.rolloutPath,
                      fileManager: fileManager
                  ) else {
                return nil
            }

            guard let metadata = sessionMetadata(
                atPath: currentThread.rolloutPath,
                fileManager: fileManager
            ), metadata.sessionId == currentSessionId else {
                return nil
            }

            let threadSource = normalized(currentThread.threadSource)?.lowercased()
            if threadSource == "automation" ||
                metadata.isAutomation ||
                metadata.isExec {
                return nil
            }

            let isSubagent = threadSource == "subagent" || metadata.isSubagent
            if isSubagent {
                guard let parentSessionId = metadata.parentSessionId,
                      parentSessionId != currentSessionId,
                      let parentThread = indexedThread(
                        sessionId: parentSessionId,
                        databasePath: databasePath,
                        fileManager: fileManager
                      ) else {
                    return nil
                }
                currentSessionId = parentSessionId
                currentThread = parentThread
                continue
            }

            guard threadSource == nil || threadSource == "user" else {
                return nil
            }
            return CodexSessionResumeEvidence(
                sessionId: currentSessionId,
                rolloutPath: currentThread.rolloutPath,
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

    private func indexedThread(
        sessionId: String,
        databasePath: String,
        fileManager: FileManager
    ) -> IndexedThread? {
        guard fileManager.fileExists(atPath: databasePath) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        var readsThreadSource = true
        if sqlite3_prepare_v2(
            database,
            "SELECT rollout_path, thread_source FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            readsThreadSource = false
            guard sqlite3_prepare_v2(
                database,
                "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
        }
        guard let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionId, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pathBytes = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let rolloutPath = (
            String(cString: pathBytes).trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        ).expandingTildeInPath
        guard !rolloutPath.isEmpty else { return nil }
        let threadSource: String?
        if readsThreadSource, let sourceBytes = sqlite3_column_text(statement, 1) {
            let value = String(cString: sourceBytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            threadSource = value.isEmpty ? nil : value
        } else {
            threadSource = nil
        }
        return IndexedThread(
            rolloutPath: rolloutPath,
            threadSource: threadSource
        )
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

        let maximumMetadataBytes = 4 * 1_024 * 1_024
        let readChunkBytes = 4 * 1_024
        var pending = Data()
        var totalBytes = 0
        var lineCount = 0

        while totalBytes <= maximumMetadataBytes, lineCount < 32 {
            let remainingBytes = maximumMetadataBytes + 1 - totalBytes
            guard let chunk = try? handle.read(upToCount: min(readChunkBytes, remainingBytes)),
                  !chunk.isEmpty else {
                return pending.isEmpty ? nil : parsedSessionMetadata(from: pending)
            }
            totalBytes += chunk.count
            guard totalBytes <= maximumMetadataBytes else { return nil }
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: 0x0A), lineCount < 32 {
                let line = Data(pending[..<newlineIndex])
                pending.removeSubrange(...newlineIndex)
                lineCount += 1
                if let metadata = parsedSessionMetadata(from: line) {
                    return metadata
                }
            }
        }
        return nil
    }

    private func parsedSessionMetadata(from data: Data) -> SessionMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionId = normalized(payload["id"] as? String) else {
            return nil
        }
        let source = payload["source"]
        let sourceIsSubagent = sourceContainsKind("subagent", value: source)
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
            isExec: sourceContainsKind("exec", value: source) || originator == "codex_exec"
        )
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
