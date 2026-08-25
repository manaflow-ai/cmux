import Foundation
import SQLite3

/// Verifies exact Codex resume identifiers against `state_5.sqlite` and rollout
/// JSONL files under the effective CODEX_HOME.
public struct CodexSessionResumeVerifier: Sendable {
    private static let maximumRolloutBytes = 8 * 1024 * 1024
    private static let maximumRolloutLines = 32
    private static let maximumFallbackCandidates = 512
    private static let maximumMatchingCandidates = 32
    private static let maximumScannedEntries = 8_192
    /// Creates a stateless Codex resume verifier.
    public init() {}

    /// Checks for an exact durable Codex rollout and records its provenance.
    /// A readable `threads` index is authoritative; rollout-only legacy installs
    /// remain supported when the index does not exist.
    ///
    /// - Parameters:
    ///   - sessionId: The exact identifier that would be passed to `codex resume`.
    ///   - transcriptPath: A hook-provided rollout candidate, when available.
    ///   - codexHome: The effective Codex state directory for the launch.
    ///   - fileManager: The filesystem implementation used for inspection.
    /// - Returns: Exact evidence, missing, or safely unavailable. Legacy scans
    ///   are bounded by bytes, lines, candidates, and entries and fail closed.
    public func verify(
        sessionId: String,
        transcriptPath: String?,
        codexHome: String,
        fileManager: FileManager = .default
    ) -> CodexSessionResumeVerification {
        guard let normalizedSessionId = normalized(sessionId) else { return .missing }
        let home = expandedPath(codexHome)
        let databasePath = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        let shouldScanLegacyRollouts: Bool
        switch indexedThread(
            sessionId: normalizedSessionId,
            databasePath: databasePath,
            codexHome: home,
            fileManager: fileManager
        ) {
        case .found(let thread):
            switch readRollout(atPath: thread.rolloutPath, fileManager: fileManager) {
            case .metadata(let metadata) where metadata.sessionId == normalizedSessionId:
                return .exists(makeEvidence(
                    sessionId: normalizedSessionId,
                    path: thread.rolloutPath,
                    source: .threadIndex,
                    metadata: metadata,
                    indexedSource: thread.indexedSource,
                    threadSource: thread.threadSource
                ))
            case .unavailable:
                // An unreadable indexed rollout is unavailable, never a
                // missing session that may fall back to weaker evidence.
                return .unavailable
            case .metadata, .readableWithoutMetadata:
                // Never accept fallback evidence after an authoritative row's
                // rollout fails identity validation.
                return .unavailable
            }
        case .databaseMissing:
            shouldScanLegacyRollouts = true
        case .threadMissing:
            shouldScanLegacyRollouts = false
        case .unavailable:
            // The rollout alone cannot recover provenance from an unreadable index.
            return .unavailable
        }

        if let transcriptPath,
           let evidence = transcriptEvidence(
               sessionId: normalizedSessionId,
               path: transcriptPath,
               codexHome: home,
               fileManager: fileManager
           ) {
            return .exists(evidence)
        }

        guard shouldScanLegacyRollouts else { return .missing }

        switch scanRollouts(
            sessionId: normalizedSessionId,
            sessionsRoot: URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
            fileManager: fileManager
        ) {
        case .found(let path, let metadata):
            return .exists(makeEvidence(
                sessionId: normalizedSessionId,
                path: path,
                source: .legacyRollout,
                metadata: metadata,
                indexedSource: nil,
                threadSource: nil
            ))
        case .notFound:
            return .missing
        case .unavailable:
            return .unavailable
        }
    }

    private struct IndexedThread {
        let rolloutPath: String
        let indexedSource: String?
        let threadSource: String?
    }

    private enum IndexLookup {
        case found(IndexedThread)
        case databaseMissing
        case threadMissing
        case unavailable
    }

    private enum RolloutRead {
        case metadata(SessionMetadata)
        case readableWithoutMetadata
        case unavailable
    }

    private enum RolloutScan {
        case found(path: String, metadata: SessionMetadata)
        case notFound
        case unavailable
    }

    private struct SessionMetadata {
        let sessionId: String
        let provenance: AgentResumeEvidenceProvenance
        let originator: String?
        let sourceDescription: String?
        let parentSessionId: String?
    }

    private func indexedThread(
        sessionId: String,
        databasePath: String,
        codexHome: String,
        fileManager: FileManager
    ) -> IndexLookup {
        guard fileManager.fileExists(atPath: databasePath) else { return .databaseMissing }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return .unavailable
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        var includesSource = true
        var includesThreadSource = true
        var prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT rollout_path, source, thread_source FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        )
        if prepareResult != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            includesThreadSource = false
            prepareResult = sqlite3_prepare_v2(
                database,
                "SELECT rollout_path, source FROM threads WHERE id = ? LIMIT 1",
                -1,
                &statement,
                nil
            )
        }
        if prepareResult != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            includesSource = false
            prepareResult = sqlite3_prepare_v2(
                database,
                "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
                -1,
                &statement,
                nil
            )
        }
        guard prepareResult == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return .unavailable
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionId, -1, transient) == SQLITE_OK else {
            return .unavailable
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { return .unavailable }
        guard step == SQLITE_ROW else { return .threadMissing }
        guard let pathBytes = sqlite3_column_text(statement, 0) else { return .unavailable }
        let rawPath = String(cString: pathBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return .unavailable }
        let indexedSource: String?
        if includesSource, let sourceBytes = sqlite3_column_text(statement, 1) {
            indexedSource = normalized(String(cString: sourceBytes))
        } else {
            indexedSource = nil
        }
        let threadSource: String?
        if includesThreadSource, let sourceBytes = sqlite3_column_text(statement, 2) {
            let value = String(cString: sourceBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            threadSource = value.isEmpty ? nil : value
        } else {
            threadSource = nil
        }
        return .found(IndexedThread(
            rolloutPath: resolvePath(rawPath, relativeTo: codexHome),
            indexedSource: indexedSource,
            threadSource: threadSource
        ))
    }

    private func transcriptEvidence(
        sessionId: String,
        path: String,
        codexHome: String,
        fileManager: FileManager
    ) -> CodexSessionResumeEvidence? {
        let resolvedPath = resolvePath(path, relativeTo: codexHome)
        switch readRollout(atPath: resolvedPath, fileManager: fileManager) {
        case .metadata(let metadata) where metadata.sessionId == sessionId:
            return makeEvidence(
                sessionId: sessionId,
                path: resolvedPath,
                source: .legacyRollout,
                metadata: metadata,
                indexedSource: nil,
                threadSource: nil
            )
        default:
            return nil
        }
    }

    private func makeEvidence(
        sessionId: String,
        path: String,
        source: CodexSessionResumeEvidence.Source,
        metadata: SessionMetadata,
        indexedSource: String?,
        threadSource: String?
    ) -> CodexSessionResumeEvidence {
        var provenance = metadata.provenance
        let indexedValue: Any? = indexedSource.flatMap { rawValue in
            guard let data = rawValue.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return rawValue
            }
            return value
        }
        if sourceContainsMarker("exec", in: indexedValue)
            || sourceContainsMarker("automation", in: indexedValue)
            || sourceContainsMarker("review", in: indexedValue) {
            provenance = .exec
        } else if sourceContainsMarker("subagent", in: indexedValue), provenance != .exec {
            provenance = .subagent
        } else if provenance == .unknown,
                  sourceContainsMarker("cli", in: indexedValue)
                    || sourceContainsMarker("tui", in: indexedValue)
                    || sourceContainsMarker("vscode", in: indexedValue) {
            provenance = .tui
        }
        if let threadSource {
            let normalizedSource = threadSource.lowercased()
            if normalizedSource.contains("exec") || normalizedSource.contains("automation") {
                provenance = .exec
            } else if normalizedSource.contains("subagent"), provenance != .exec {
                provenance = .subagent
            }
        }
        return CodexSessionResumeEvidence(
            sessionId: sessionId,
            rolloutPath: path,
            source: source,
            provenance: provenance,
            originator: metadata.originator,
            sessionMetaSource: metadata.sourceDescription,
            parentSessionId: metadata.parentSessionId
        )
    }

    private func scanRollouts(
        sessionId: String,
        sessionsRoot: URL,
        fileManager: FileManager
    ) -> RolloutScan {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory) else {
            return .notFound
        }
        guard isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return .unavailable
        }

        var fallbackCandidates: [URL] = []
        var sawUnavailable = false
        var scannedEntries = 0
        var matchingCandidates = 0
        while let item = enumerator.nextObject() as? URL {
            scannedEntries += 1
            if scannedEntries > Self.maximumScannedEntries {
                return .unavailable
            }
            guard item.pathExtension.lowercased() == "jsonl" else { continue }
            if item.lastPathComponent.contains(sessionId) {
                matchingCandidates += 1
                guard matchingCandidates <= Self.maximumMatchingCandidates else {
                    return .unavailable
                }
                // Parse focused filenames while walking so a hit avoids
                // traversing and reopening every file in the sessions tree.
                switch readRollout(atPath: item.path, fileManager: fileManager) {
                case .metadata(let metadata) where metadata.sessionId == sessionId:
                    return .found(path: item.path, metadata: metadata)
                case .unavailable:
                    sawUnavailable = true
                default:
                    continue
                }
            } else if fallbackCandidates.count < Self.maximumFallbackCandidates {
                fallbackCandidates.append(item)
            }
        }
        for candidate in fallbackCandidates {
            switch readRollout(atPath: candidate.path, fileManager: fileManager) {
            case .metadata(let metadata) where metadata.sessionId == sessionId:
                return .found(path: candidate.path, metadata: metadata)
            case .unavailable:
                sawUnavailable = true
            default:
                continue
            }
        }
        return sawUnavailable ? .unavailable : .notFound
    }

    private func readRollout(atPath path: String, fileManager: FileManager) -> RolloutRead {
        guard regularNonEmptyFileExists(atPath: path, fileManager: fileManager),
              let handle = FileHandle(forReadingAtPath: path) else {
            return .unavailable
        }
        defer { try? handle.close() }

        var pending = Data()
        var totalBytes = 0
        var lineCount = 0
        var sawJSON = false
        while totalBytes < Self.maximumRolloutBytes, lineCount < Self.maximumRolloutLines {
            guard let chunk = try? handle.read(upToCount: min(64 * 1024, Self.maximumRolloutBytes - totalBytes)),
                  !chunk.isEmpty else {
                break
            }
            totalBytes += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A), lineCount < Self.maximumRolloutLines {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                lineCount += 1
                if let object = jsonObject(line) {
                    sawJSON = true
                    if let metadata = sessionMetadata(from: object) {
                        return .metadata(metadata)
                    }
                }
            }
        }
        if totalBytes >= Self.maximumRolloutBytes && !pending.contains(0x0A) {
            return .unavailable
        }
        if !pending.isEmpty, let object = jsonObject(pending) {
            sawJSON = true
            if let metadata = sessionMetadata(from: object) {
                return .metadata(metadata)
            }
        }
        return sawJSON ? .readableWithoutMetadata : .unavailable
    }

    private func sessionMetadata(from object: [String: Any]) -> SessionMetadata? {
        guard object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionId = normalized(payload["id"] as? String) else {
            return nil
        }
        let source = payload["source"]
        let sourceDescription = normalized(source as? String)
        let originator = normalized(payload["originator"] as? String)
        let parentSessionId = normalized(payload["parent_thread_id"] as? String)
            ?? normalized(payload["forked_from_id"] as? String)
            ?? nestedString(forKey: "parent_thread_id", in: source)
        let isExec = sourceContainsMarker("exec", in: source)
            || sourceContainsMarker("review", in: source)
            || originator?.lowercased().contains("codex_exec") == true
            || originator?.lowercased().contains("review") == true
        let isSubagent = sourceContainsMarker("subagent", in: source)
            || normalized(payload["thread_source"] as? String)?.lowercased() == "subagent"
        let provenance: AgentResumeEvidenceProvenance
        if isExec {
            provenance = .exec
        } else if isSubagent {
            provenance = .subagent
        } else if sourceContainsMarker("cli", in: source)
                    || sourceContainsMarker("tui", in: source)
                    || sourceContainsMarker("vscode", in: source) {
            provenance = .tui
        } else {
            provenance = .unknown
        }
        return SessionMetadata(
            sessionId: sessionId,
            provenance: provenance,
            originator: originator,
            sourceDescription: sourceDescription,
            parentSessionId: parentSessionId
        )
    }

    private func sourceContainsMarker(_ marker: String, in value: Any?) -> Bool {
        let normalizedMarker = marker.lowercased()
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedMarker
        }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key.lowercased() == normalizedMarker || sourceContainsMarker(marker, in: child) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains { sourceContainsMarker(marker, in: $0) }
        }
        return false
    }

    private func nestedString(forKey key: String, in value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            for (childKey, child) in dictionary {
                if childKey == key, let result = normalized(child as? String) { return result }
                if let result = nestedString(forKey: key, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = nestedString(forKey: key, in: child) {
                    return result
                }
            }
        }
        return nil
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private func resolvePath(_ rawPath: String, relativeTo base: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
            .standardizedFileURL.path
    }

    private func expandedPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
