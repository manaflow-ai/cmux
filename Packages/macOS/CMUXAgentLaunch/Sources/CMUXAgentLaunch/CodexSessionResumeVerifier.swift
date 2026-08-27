import Foundation
import SQLite3

/// Verifies exact Codex resume identifiers against `state_5.sqlite` and rollout
/// JSONL files under the effective CODEX_HOME.
public struct CodexSessionResumeVerifier: Sendable {
    private let legacyRolloutScanner: CodexLegacyRolloutScanner

    /// Creates a stateless Codex resume verifier.
    public init() {
        legacyRolloutScanner = CodexLegacyRolloutScanner()
    }

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
        verifyBatch(
            [CodexSessionResumeVerificationRequest(
                sessionId: sessionId,
                transcriptPath: transcriptPath
            )],
            codexHome: codexHome,
            fileManager: fileManager
        ).first ?? .missing
    }

    /// Verifies several Codex identities against one state directory.
    ///
    /// The legacy rollout fallback is walked at most once for the whole batch.
    /// This keeps hook-store reconciliation bounded when an older Codex install
    /// has no `state_5.sqlite` and the store contains many historical records.
    /// Requests and results are aligned by array index, so callers may retain
    /// distinct transcript candidates for the same session identifier.
    ///
    /// - Parameters:
    ///   - requests: The exact identities and optional hook rollout candidates.
    ///   - codexHome: The effective Codex state directory.
    ///   - fileManager: The filesystem implementation used for inspection.
    /// - Returns: Results for at most the configured maximum batch size.
    public func verifyBatch(
        _ requests: [CodexSessionResumeVerificationRequest],
        codexHome: String,
        fileManager: FileManager = .default
    ) -> [CodexSessionResumeVerification] {
        var readBudget = CodexSessionResumeVerificationLimits()
        return verifyBatch(
            requests,
            codexHome: codexHome,
            readBudget: &readBudget,
            fileManager: fileManager
        )
    }

    /// Verifies several identities while consuming a caller-owned byte budget.
    ///
    /// Sharing the budget across homes lets an index load bound its total
    /// filesystem work, rather than applying the limit independently to every
    /// account directory.
    ///
    /// - Parameters:
    ///   - requests: The exact identities and optional hook rollout candidates.
    ///   - codexHome: The effective Codex state directory.
    ///   - readBudget: Shared aggregate rollout-read budget.
    ///   - fileManager: The filesystem implementation used for inspection.
    /// - Returns: Results for at most the configured maximum batch size.
    public func verifyBatch(
        _ requests: [CodexSessionResumeVerificationRequest],
        codexHome: String,
        readBudget: inout CodexSessionResumeVerificationLimits,
        fileManager: FileManager = .default
    ) -> [CodexSessionResumeVerification] {
        guard !requests.isEmpty else { return [] }
        let home = expandedPath(codexHome)
        let databasePath = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("state_5.sqlite", isDirectory: false)
            .path

        let verificationRequests = requests.prefix(
            CodexSessionResumeVerificationLimits.maximumBatchRequests
        ).map { request in
            CodexSessionResumeVerificationRequest(
                sessionId: normalized(request.sessionId) ?? "",
                transcriptPath: normalized(request.transcriptPath)
            )
        }
        var results = Array(
            repeating: CodexSessionResumeVerification.missing,
            count: verificationRequests.count
        )
        // A missing database is the only state in which the legacy rollout
        // tree is authoritative. Resolve hook transcripts first, then perform
        // one bounded walk for every remaining identifier.
        guard fileManager.fileExists(atPath: databasePath) else {
            var unresolvedSessionIDs = Set<String>()
            for (index, request) in verificationRequests.enumerated() {
                guard !request.sessionId.isEmpty else { continue }
                if let transcriptPath = request.transcriptPath,
                   let evidence = transcriptEvidence(
                       sessionId: request.sessionId,
                       path: transcriptPath,
                       codexHome: home,
                       fileManager: fileManager,
                       readBudget: &readBudget
                   ) {
                    results[index] = .exists(evidence)
                } else {
                    unresolvedSessionIDs.insert(request.sessionId)
                }
            }
            if !unresolvedSessionIDs.isEmpty {
                let scan = legacyRolloutScanner.scan(
                    sessionIDs: unresolvedSessionIDs,
                    sessionsRoot: URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent("sessions", isDirectory: true),
                    fileManager: fileManager,
                    readBudget: &readBudget
                )
                for (index, request) in verificationRequests.enumerated()
                    where !request.sessionId.isEmpty && results[index] == .missing {
                    if let match = scan.found[request.sessionId] {
                        results[index] = .exists(makeEvidence(
                            sessionId: request.sessionId,
                            path: match.path,
                            source: .legacyRollout,
                            metadata: match.metadata,
                            indexedSource: nil,
                            threadSource: nil
                        ))
                    } else if scan.sawUnavailable {
                        results[index] = .unavailable
                    }
                }
            }
            return results
        }

        guard let indexedResults = indexedThreads(
            sessionIDs: Set(verificationRequests.map(\.sessionId).filter { !$0.isEmpty }),
            databasePath: databasePath,
            codexHome: home,
            fileManager: fileManager
        ) else {
            for index in verificationRequests.indices where !verificationRequests[index].sessionId.isEmpty {
                results[index] = .unavailable
            }
            return results
        }
        for (index, request) in verificationRequests.enumerated() {
            guard !request.sessionId.isEmpty else { continue }
            switch indexedResults[request.sessionId] ?? .threadMissing {
            case .found(let thread):
                switch legacyRolloutScanner.readRollout(
                    atPath: thread.rolloutPath,
                    fileManager: fileManager,
                    readBudget: &readBudget
                ) {
                case .metadata(let metadata) where metadata.sessionId == request.sessionId:
                    results[index] = .exists(makeEvidence(
                        sessionId: request.sessionId,
                        path: thread.rolloutPath,
                        source: .threadIndex,
                        metadata: metadata,
                        indexedSource: thread.indexedSource,
                        threadSource: thread.threadSource
                    ))
                case .unavailable, .metadata, .readableWithoutMetadata:
                    // An indexed row is authoritative. Never accept weaker
                    // transcript or legacy evidence after it fails identity
                    // validation.
                    results[index] = .unavailable
                }
            case .threadMissing:
                if let transcriptPath = request.transcriptPath,
                   let evidence = transcriptEvidence(
                       sessionId: request.sessionId,
                       path: transcriptPath,
                       codexHome: home,
                       fileManager: fileManager,
                       readBudget: &readBudget
                   ) {
                    results[index] = .exists(evidence)
                } else if !readBudget.hasRemainingBytes {
                    // A shared budget exhaustion is an inconclusive read, not
                    // evidence that this indexed-missing thread is absent.
                    results[index] = .unavailable
                }
            case .databaseMissing, .unavailable:
                // The database existed when the batch started, so a race
                // that removes it or makes it unreadable is unavailable.
                results[index] = .unavailable
            }
        }
        return results
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

    private func indexedThreads(
        sessionIDs: Set<String>,
        databasePath: String,
        codexHome: String,
        fileManager: FileManager
    ) -> [String: IndexLookup]? {
        guard !sessionIDs.isEmpty else { return [:] }
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
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var results: [String: IndexLookup] = [:]
        for sessionID in sessionIDs {
            guard sqlite3_reset(statement) == SQLITE_OK,
                  sqlite3_clear_bindings(statement) == SQLITE_OK,
                  sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else {
                return nil
            }
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW || step == SQLITE_DONE else { return nil }
            guard step == SQLITE_ROW else {
                results[sessionID] = .threadMissing
                continue
            }
            guard let pathBytes = sqlite3_column_text(statement, 0) else {
                results[sessionID] = .unavailable
                continue
            }
            let rawPath = String(cString: pathBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else {
                results[sessionID] = .unavailable
                continue
            }
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
            results[sessionID] = .found(IndexedThread(
                rolloutPath: resolvePath(rawPath, relativeTo: codexHome),
                indexedSource: indexedSource,
                threadSource: threadSource
            ))
        }
        return results
    }

    private func transcriptEvidence(
        sessionId: String,
        path: String,
        codexHome: String,
        fileManager: FileManager,
        readBudget: inout CodexSessionResumeVerificationLimits
    ) -> CodexSessionResumeEvidence? {
        let resolvedPath = resolvePath(path, relativeTo: codexHome)
        switch legacyRolloutScanner.readRollout(
            atPath: resolvedPath,
            fileManager: fileManager,
            readBudget: &readBudget
        ) {
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
        metadata: CodexLegacyRolloutScanner.SessionMetadata,
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
        if legacyRolloutScanner.sourceContainsMarker("exec", in: indexedValue)
            || legacyRolloutScanner.sourceContainsMarker("automation", in: indexedValue)
            || legacyRolloutScanner.sourceContainsMarker("review", in: indexedValue) {
            provenance = .exec
        } else if legacyRolloutScanner.sourceContainsMarker("subagent", in: indexedValue), provenance != .exec {
            provenance = .subagent
        } else if provenance == .unknown,
                  legacyRolloutScanner.sourceContainsMarker("cli", in: indexedValue)
                    || legacyRolloutScanner.sourceContainsMarker("tui", in: indexedValue)
                    || legacyRolloutScanner.sourceContainsMarker("vscode", in: indexedValue) {
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
