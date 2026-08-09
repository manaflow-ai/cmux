import Foundation

/// Recovers transient Hermes identities persisted instead of a durable conversation.
///
/// Hermes's TUI exposes a short transport identifier before its durable
/// `state.db` session is created. Hermes 0.20 approval callbacks could also
/// omit the conversation key and fall back to the cmux surface UUID. Recovery
/// accepts only database-backed process-generation evidence or one unique TUI
/// row inside the matching hook lifecycle boundary.
public struct HermesLegacySessionIdentityRecovery: Sendable {
    /// Creates a resolver for legacy Hermes conversation identities.
    public init() {}

    /// The authoritative Hermes identity recovered from hook and state stores.
    public struct Result: Equatable, Sendable {
        /// The durable Hermes conversation identifier that replaces the transient identity.
        public let sessionID: String
        /// The launch command captured for the recovered conversation, when available.
        public let launchCommand: AgentLaunchCommand?

        /// Creates a recovered Hermes conversation identity.
        ///
        /// - Parameters:
        ///   - sessionID: The authoritative Hermes conversation identifier.
        ///   - launchCommand: The captured launch command, when available.
        public init(sessionID: String, launchCommand: AgentLaunchCommand?) {
            self.sessionID = sessionID
            self.launchCommand = launchCommand
        }
    }

    private struct HookStore: Decodable {
        let sessions: [String: HookRecord]
    }

    private struct HookRecord: Decodable {
        let sessionId: String
        let workspaceId: String
        let surfaceId: String
        let cwd: String?
        let pid: Int?
        let pidStartSeconds: Int64?
        let pidStartMicroseconds: Int64?
        let launchCommand: AgentLaunchCommand?
        let startedAt: TimeInterval
        let updatedAt: TimeInterval
    }

    /// Reads batched recovery evidence from one resolved Hermes database path.
    typealias RecoveryDatabaseInspector = (
        _ sessionIDs: Set<String>,
        _ cwd: String?,
        _ startedAt: TimeInterval?,
        _ upperBound: TimeInterval?,
        _ stateDBPath: String
    ) -> HermesAgentIndex.RecoveryInspection?

    /// A same-process hook record paired with its resolved database path.
    private struct Candidate {
        let record: HookRecord
        let sessionID: String
        let stateDBPath: String
    }

    /// Recovers the durable Hermes conversation associated with a transient checkpoint.
    ///
    /// - Parameters:
    ///   - surfaceID: The cmux surface that owns the transient checkpoint.
    ///   - corruptSessionID: The persisted checkpoint that Hermes cannot resume.
    ///   - expectedWorkspaceID: The workspace that must own the hook record, when known.
    ///   - hookStateFileURL: The Hermes hook-session store to inspect.
    ///   - environment: The launch environment used to resolve the Hermes state database.
    /// - Returns: The authoritative conversation and launch command, or `nil` when the evidence is incomplete.
    public func recover(
        surfaceID: UUID,
        corruptSessionID: String,
        expectedWorkspaceID: UUID? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result? {
        recover(
            surfaceID: surfaceID,
            corruptSessionID: corruptSessionID,
            expectedWorkspaceID: expectedWorkspaceID,
            hookStateFileURL: hookStateFileURL,
            environment: environment,
            databaseInspector: { sessionIDs, cwd, startedAt, upperBound, stateDBPath in
                HermesAgentIndex.recoveryInspection(
                    sessionIDs: sessionIDs,
                    cwd: cwd,
                    startedAt: startedAt,
                    before: upperBound,
                    stateDBPath: stateDBPath
                )
            }
        )
    }

    func recover(
        surfaceID: UUID,
        corruptSessionID: String,
        expectedWorkspaceID: UUID? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        databaseInspector: RecoveryDatabaseInspector
    ) -> Result? {
        let normalizedCorruptSessionID = normalized(corruptSessionID)
        guard let normalizedCorruptSessionID,
              let data = try? Data(contentsOf: hookStateFileURL),
              let state = try? JSONDecoder().decode(HookStore.self, from: data),
              let corruptRecord = state.sessions[normalizedCorruptSessionID]
                ?? state.sessions.values.first(where: {
                    $0.sessionId.caseInsensitiveCompare(normalizedCorruptSessionID) == .orderedSame
                }),
              corruptRecord.surfaceId.caseInsensitiveCompare(surfaceID.uuidString) == .orderedSame,
              expectedWorkspaceID.map({
                  corruptRecord.workspaceId.caseInsensitiveCompare($0.uuidString) == .orderedSame
              }) ?? true,
              let corruptPID = corruptRecord.pid,
              corruptPID > 0,
              let corruptPIDStartSeconds = corruptRecord.pidStartSeconds,
              let corruptPIDStartMicroseconds = corruptRecord.pidStartMicroseconds else {
            return nil
        }

        let corruptEnvironment = stateEnvironment(
            base: environment,
            launchCommand: corruptRecord.launchCommand
        )
        let corruptStateDBPath = normalizedStateDBPath(
            HermesAgentSessionResolver.stateDBPath(env: corruptEnvironment)
        )

        let matchingRecords = state.sessions.values.filter { record in
            guard let candidateSessionID = normalized(record.sessionId) else { return false }
            return candidateSessionID.caseInsensitiveCompare(normalizedCorruptSessionID) != .orderedSame
                && record.surfaceId.caseInsensitiveCompare(corruptRecord.surfaceId) == .orderedSame
                && record.workspaceId.caseInsensitiveCompare(corruptRecord.workspaceId) == .orderedSame
                && record.pid == corruptPID
                && record.pidStartSeconds == corruptPIDStartSeconds
                && record.pidStartMicroseconds == corruptPIDStartMicroseconds
        }.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.sessionId < $1.sessionId
        }

        let candidates = matchingRecords.compactMap { record -> Candidate? in
            guard let sessionID = normalized(record.sessionId) else { return nil }
            let candidateEnvironment = stateEnvironment(
                base: environment,
                launchCommand: record.launchCommand
            )
            return Candidate(
                record: record,
                sessionID: sessionID,
                stateDBPath: normalizedStateDBPath(
                    HermesAgentSessionResolver.stateDBPath(env: candidateEnvironment)
                )
            )
        }

        let cwd = normalized(corruptRecord.cwd)
            ?? normalized(corruptRecord.launchCommand?.workingDirectory)
        let nextProcessBoundary = state.sessions.values.compactMap { record -> TimeInterval? in
            guard record.surfaceId.caseInsensitiveCompare(corruptRecord.surfaceId) == .orderedSame,
                  record.workspaceId.caseInsensitiveCompare(corruptRecord.workspaceId) == .orderedSame,
                  record.startedAt > corruptRecord.startedAt,
                  !sameProcessGeneration(
                      record,
                      pid: corruptPID,
                      startSeconds: corruptPIDStartSeconds,
                      startMicroseconds: corruptPIDStartMicroseconds
                  ) else {
                return nil
            }
            return record.startedAt
        }.min()

        var requestedSessionIDsByPath: [String: Set<String>] = [
            corruptStateDBPath: [normalizedCorruptSessionID]
        ]
        for candidate in candidates {
            requestedSessionIDsByPath[candidate.stateDBPath, default: []]
                .formUnion([normalizedCorruptSessionID, candidate.sessionID])
        }

        var inspectionsByPath: [String: HermesAgentIndex.RecoveryInspection] = [:]
        for stateDBPath in requestedSessionIDsByPath.keys.sorted() {
            let includesLifecycleEvidence = stateDBPath == corruptStateDBPath
            guard let inspection = databaseInspector(
                requestedSessionIDsByPath[stateDBPath] ?? [],
                includesLifecycleEvidence ? cwd : nil,
                includesLifecycleEvidence ? corruptRecord.startedAt : nil,
                includesLifecycleEvidence ? nextProcessBoundary : nil,
                stateDBPath
            ) else {
                continue
            }
            inspectionsByPath[stateDBPath] = inspection
        }

        let corruptExistence = inspectionsByPath[corruptStateDBPath]?
            .existence(of: normalizedCorruptSessionID) ?? .unavailable
        guard corruptExistence != .exists else { return nil }

        let databaseBackedCandidates = candidates.filter { candidate in
            guard let inspection = inspectionsByPath[candidate.stateDBPath] else {
                return false
            }
            return inspection.existence(of: normalizedCorruptSessionID) == .missing
                && inspection.existence(of: candidate.sessionID) == .exists
        }
        if databaseBackedCandidates.count == 1,
           let candidate = databaseBackedCandidates.first,
           candidate.sessionID.caseInsensitiveCompare(normalizedCorruptSessionID) != .orderedSame {
            return Result(
                sessionID: candidate.sessionID,
                launchCommand: candidate.record.launchCommand
            )
        }
        guard databaseBackedCandidates.isEmpty else { return nil }

        guard corruptExistence == .missing,
              cwd != nil,
              let corruptInspection = inspectionsByPath[corruptStateDBPath] else {
            return nil
        }
        let matches = corruptInspection.evidence.filter {
            $0.sessionID.caseInsensitiveCompare(normalizedCorruptSessionID) != .orderedSame
        }
        guard matches.count == 1, let recovered = matches.first else { return nil }
        let matchingHookRecord = state.sessions.values.first {
            $0.sessionId.caseInsensitiveCompare(recovered.sessionID) == .orderedSame
        }
        return Result(
            sessionID: recovered.sessionID,
            launchCommand: matchingHookRecord?.launchCommand ?? corruptRecord.launchCommand
        )
    }

    private func stateEnvironment(
        base: [String: String],
        launchCommand: AgentLaunchCommand?
    ) -> [String: String] {
        var merged = base
        if let launchEnvironment = launchCommand?.environment {
            merged.merge(launchEnvironment) { _, captured in captured }
        }
        return merged
    }

    private func sameProcessGeneration(
        _ record: HookRecord,
        pid: Int,
        startSeconds: Int64,
        startMicroseconds: Int64
    ) -> Bool {
        record.pid == pid
            && record.pidStartSeconds == startSeconds
            && record.pidStartMicroseconds == startMicroseconds
    }

    private func normalizedStateDBPath(_ value: String) -> String {
        (value as NSString).standardizingPath
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
