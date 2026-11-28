import Foundation
import SQLite3

extension HermesAgentIndex {
    /// One resumable TUI row correlated to a legacy hook lifecycle.
    struct RecoveryEvidence: Equatable, Sendable {
        let sessionID: String
        let source: String
        let startedAt: TimeInterval
        let cwd: String?
    }

    /// The batched identity and lifecycle result from one database snapshot.
    struct RecoveryInspection: Equatable, Sendable {
        let existingSessionIDs: Set<String>
        let evidence: [RecoveryEvidence]

        func existence(of sessionID: String) -> HermesAgentSessionExistence {
            existingSessionIDs.contains(sessionID) ? .exists : .missing
        }
    }

    /// Determines whether Hermes can resume an exact session identifier.
    ///
    /// A private writable snapshot is used so databases left in persistent WAL
    /// mode remain readable without mutating Hermes's live files.
    ///
    /// - Parameters:
    ///   - sessionID: The exact Hermes session identifier to validate.
    ///   - stateDBPath: The Hermes `state.db` path to inspect.
    /// - Returns: Whether the identifier exists, is missing, or could not be checked.
    public static func sessionExistence(
        sessionID: String,
        stateDBPath: String = Self.defaultStateDBPath()
    ) -> HermesAgentSessionExistence {
        guard let sessionID = normalized(sessionID) else { return .missing }
        guard let inspection = recoveryInspection(
            sessionIDs: [sessionID],
            cwd: nil,
            startedAt: nil,
            before: nil,
            stateDBPath: stateDBPath
        ) else { return .unavailable }
        return inspection.existence(of: sessionID)
    }

    /// Determines the existence of several Hermes identifiers from one database snapshot.
    ///
    /// Callers that validate a hook store use this batched form so WAL snapshot work is
    /// bounded by unique Hermes homes rather than by hook-record count.
    public static func sessionExistences(
        sessionIDs: Set<String>,
        stateDBPath: String = Self.defaultStateDBPath()
    ) -> [String: HermesAgentSessionExistence]? {
        let normalizedSessionIDs = Set(sessionIDs.compactMap(normalized))
        guard !normalizedSessionIDs.isEmpty else { return [:] }
        guard let inspection = recoveryInspection(
            sessionIDs: normalizedSessionIDs,
            cwd: nil,
            startedAt: nil,
            before: nil,
            stateDBPath: stateDBPath
        ) else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: normalizedSessionIDs.map { sessionID in
            (sessionID, inspection.existence(of: sessionID))
        })
    }

    /// Reads all identity and lifecycle evidence needed for recovery from one
    /// private snapshot. Callers batch every candidate that resolves to the
    /// same database path so file I/O is bounded by databases, not hooks.
    static func recoveryInspection(
        sessionIDs: Set<String>,
        cwd: String?,
        startedAt: TimeInterval?,
        before upperBound: TimeInterval?,
        stateDBPath: String
    ) -> RecoveryInspection? {
        let normalizedSessionIDs = Set(sessionIDs.compactMap(normalized))
        let cwdCandidates = cwd.map {
            HermesAgentStateDBResolver().cwdMatchCandidates(for: $0)
        } ?? []
        guard !normalizedSessionIDs.isEmpty || (startedAt != nil && !cwdCandidates.isEmpty) else {
            return RecoveryInspection(existingSessionIDs: [], evidence: [])
        }
        let snapshot: HermesAgentDatabaseSnapshot
        do {
            guard let madeSnapshot = try makeSnapshot(
                stateDBPath: stateDBPath,
                prefix: "cmux-hermes-agent-recovery"
            ) else {
                return nil
            }
            snapshot = madeSnapshot
        } catch {
            return nil
        }
        defer { snapshot.remove() }

        do {
            return try withDatabase(snapshot.databaseURL.path) { database in
                try loadRecoveryInspection(
                    database: database,
                    sessionIDs: normalizedSessionIDs,
                    cwdCandidates: cwdCandidates,
                    startedAt: startedAt,
                    upperBound: upperBound
                )
            }
        } catch {
            return nil
        }
    }

    private static func loadRecoveryInspection(
        database: OpaquePointer,
        sessionIDs: Set<String>,
        cwdCandidates: [String],
        startedAt: TimeInterval?,
        upperBound: TimeInterval?
    ) throws -> RecoveryInspection {
        let sortedSessionIDs = sessionIDs.sorted()
        let hasCwdColumn = HermesAgentStateDBResolver().sessionsHaveCwdColumn(database)
        let includesLifecycleEvidence = hasCwdColumn
            && startedAt != nil
            && !cwdCandidates.isEmpty

        var predicates: [String] = []
        if !sortedSessionIDs.isEmpty {
            predicates.append("id IN (\(sortedSessionIDs.map { _ in "?" }.joined(separator: ", ")))")
        }
        if includesLifecycleEvidence {
            let cwdPlaceholders = cwdCandidates.map { _ in "?" }.joined(separator: ", ")
            var lifecyclePredicate = "(source = 'tui' AND started_at >= ? AND cwd IN (\(cwdPlaceholders))"
            if upperBound != nil {
                lifecyclePredicate += " AND started_at < ?"
            }
            lifecyclePredicate += ")"
            predicates.append(lifecyclePredicate)
        }
        guard !predicates.isEmpty else {
            return RecoveryInspection(existingSessionIDs: [], evidence: [])
        }

        let cwdColumn = hasCwdColumn ? "cwd" : "NULL AS cwd"
        let sql = """
            SELECT id, source, started_at, \(cwdColumn)
            FROM sessions
            WHERE source IN (\(knownSources.map { "'\($0)'" }.joined(separator: ", ")))
              AND (\(predicates.joined(separator: " OR ")))
            ORDER BY started_at, id
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        let destructor = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        for sessionID in sortedSessionIDs {
            guard sqlite3_bind_text(statement, bindIndex, sessionID, -1, destructor) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "bind failed")
            }
            bindIndex += 1
        }
        if includesLifecycleEvidence, let startedAt {
            guard sqlite3_bind_double(statement, bindIndex, startedAt) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "bind failed")
            }
            bindIndex += 1
        }
        for cwd in includesLifecycleEvidence ? cwdCandidates : [] {
            guard sqlite3_bind_text(statement, bindIndex, cwd, -1, destructor) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "bind failed")
            }
            bindIndex += 1
        }
        if includesLifecycleEvidence, let upperBound {
            guard sqlite3_bind_double(statement, bindIndex, upperBound) == SQLITE_OK else {
                throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "bind failed")
            }
        }

        var existingSessionIDs: Set<String> = []
        var evidence: [RecoveryEvidence] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let sessionID = normalized(sqliteText(statement, 0)),
                  let source = normalized(sqliteText(statement, 1)) else {
                stepResult = sqlite3_step(statement)
                continue
            }
            let rowStartedAt = sqlite3_column_double(statement, 2)
            let rowCwd = normalized(sqliteText(statement, 3))
            if sessionIDs.contains(sessionID) {
                existingSessionIDs.insert(sessionID)
            }
            if includesLifecycleEvidence,
               source == "tui",
               let startedAt,
               rowStartedAt >= startedAt,
               upperBound.map({ rowStartedAt < $0 }) ?? true,
               rowCwd.map(cwdCandidates.contains) == true {
                evidence.append(RecoveryEvidence(
                    sessionID: sessionID,
                    source: source,
                    startedAt: rowStartedAt,
                    cwd: rowCwd
                ))
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw HermesAgentIndexError.sqlite(sqliteMessage(database) ?? "step failed")
        }
        return RecoveryInspection(
            existingSessionIDs: existingSessionIDs,
            evidence: evidence
        )
    }
}
