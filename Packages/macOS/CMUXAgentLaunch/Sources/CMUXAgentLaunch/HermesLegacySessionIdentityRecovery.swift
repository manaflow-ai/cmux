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

    /// The authoritative disposition of one persisted Hermes checkpoint.
    public enum Resolution: Equatable, Sendable {
        /// The requested identifier already exists in Hermes's durable database.
        case valid
        /// A durable identifier is valid but must be re-armed after a legacy launch failure.
        case legacyRestore(Result)
        /// A unique durable identifier replaces the requested transient identifier.
        case recovered(Result)
        /// The database was readable and contains no safe checkpoint to launch.
        case missing
        /// Hermes's database could not be inspected safely; preserve existing state.
        case unavailable
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
        let runtimeStatus: String?
        let agentLifecycle: String?
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
    ///   - expectedWorkingDirectory: The saved pane directory used to reject a transport from another launch.
    ///   - hookStateFileURL: The Hermes hook-session store to inspect.
    ///   - environment: The launch environment used to resolve the Hermes state database.
    /// - Returns: The authoritative conversation and launch command, or `nil` when the evidence is incomplete.
    public func recover(
        surfaceID: UUID,
        corruptSessionID: String,
        expectedWorkspaceID: UUID? = nil,
        expectedWorkingDirectory: String? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result? {
        guard case .recovered(let result) = resolve(
            surfaceID: surfaceID,
            corruptSessionID: corruptSessionID,
            expectedWorkspaceID: expectedWorkspaceID,
            expectedWorkingDirectory: expectedWorkingDirectory,
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
        ) else {
            return nil
        }
        return result
    }

    /// Validates or recovers one persisted Hermes checkpoint.
    public func resolve(
        surfaceID: UUID,
        corruptSessionID: String,
        expectedWorkspaceID: UUID? = nil,
        expectedWorkingDirectory: String? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolution {
        resolve(
            surfaceID: surfaceID,
            corruptSessionID: corruptSessionID,
            expectedWorkspaceID: expectedWorkspaceID,
            expectedWorkingDirectory: expectedWorkingDirectory,
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
        expectedWorkingDirectory: String? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        databaseInspector: RecoveryDatabaseInspector
    ) -> Result? {
        guard case .recovered(let result) = resolve(
            surfaceID: surfaceID,
            corruptSessionID: corruptSessionID,
            expectedWorkspaceID: expectedWorkspaceID,
            expectedWorkingDirectory: expectedWorkingDirectory,
            hookStateFileURL: hookStateFileURL,
            environment: environment,
            databaseInspector: databaseInspector
        ) else {
            return nil
        }
        return result
    }

    func resolve(
        surfaceID: UUID,
        corruptSessionID: String,
        expectedWorkspaceID: UUID? = nil,
        expectedWorkingDirectory: String? = nil,
        hookStateFileURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        databaseInspector: RecoveryDatabaseInspector
    ) -> Resolution {
        let normalizedCorruptSessionID = normalized(corruptSessionID)
        guard let normalizedCorruptSessionID else { return .missing }

        guard let data = try? Data(contentsOf: hookStateFileURL),
              let state = try? JSONDecoder().decode(HookStore.self, from: data) else {
            return exactResolution(
                sessionID: normalizedCorruptSessionID,
                environment: environment,
                databaseInspector: databaseInspector
            )
        }

        let corruptRecord = state.sessions[normalizedCorruptSessionID]
            ?? state.sessions.values.first(where: {
                $0.sessionId.caseInsensitiveCompare(normalizedCorruptSessionID) == .orderedSame
            })
        guard let corruptRecord,
              record(
                  corruptRecord,
                  belongsTo: surfaceID,
                  expectedWorkspaceID: expectedWorkspaceID
              ) else {
            return detachedDurableResolution(
                state: state,
                requestedSessionID: normalizedCorruptSessionID,
                surfaceID: surfaceID,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedWorkingDirectory: expectedWorkingDirectory,
                displacedRecord: corruptRecord,
                environment: environment,
                databaseInspector: databaseInspector
            )
        }

        let corruptEnvironment = stateEnvironment(
            base: environment,
            launchCommand: corruptRecord.launchCommand
        )
        guard let corruptPID = corruptRecord.pid,
              corruptPID > 0,
              let corruptPIDStartSeconds = corruptRecord.pidStartSeconds,
              let corruptPIDStartMicroseconds = corruptRecord.pidStartMicroseconds else {
            return exactResolution(
                sessionID: normalizedCorruptSessionID,
                environment: corruptEnvironment,
                databaseInspector: databaseInspector
            )
        }

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
        if corruptExistence == .exists {
            // A completed turn marks the durable conversation idle even though
            // Hermes's TUI transport is still running. The missing transient
            // sibling is the process-liveness record for this legacy pairing;
            // requiring the durable row to stay running disarms the next launch.
            let transientCandidates = candidates.filter { candidate in
                candidate.stateDBPath == corruptStateDBPath
                    && inspectionsByPath[corruptStateDBPath]?
                        .existence(of: candidate.sessionID) == .missing
                    && recordReportsRunningLifecycle(candidate.record)
                    && recordsMatchWorkingDirectory(corruptRecord, candidate.record)
            }
            if transientCandidates.count == 1, let transientCandidate = transientCandidates.first {
                return .legacyRestore(Result(
                    sessionID: normalizedCorruptSessionID,
                    launchCommand: corruptRecord.launchCommand
                        ?? transientCandidate.record.launchCommand
                ))
            }
            return .valid
        }
        guard corruptExistence == .missing else { return .unavailable }
        guard requestedSessionIDsByPath.keys.allSatisfy({ inspectionsByPath[$0] != nil }) else {
            return .unavailable
        }

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
            return .recovered(Result(
                sessionID: candidate.sessionID,
                launchCommand: candidate.record.launchCommand
            ))
        }
        guard databaseBackedCandidates.isEmpty else { return .missing }

        guard cwd != nil,
              let corruptInspection = inspectionsByPath[corruptStateDBPath] else {
            return .missing
        }
        let matches = corruptInspection.evidence.filter {
            $0.sessionID.caseInsensitiveCompare(normalizedCorruptSessionID) != .orderedSame
        }
        guard matches.count == 1, let recovered = matches.first else { return .missing }
        let matchingHookRecord = state.sessions.values.first {
            $0.sessionId.caseInsensitiveCompare(recovered.sessionID) == .orderedSame
        }
        return .recovered(Result(
            sessionID: recovered.sessionID,
            launchCommand: matchingHookRecord?.launchCommand ?? corruptRecord.launchCommand
        ))
    }

    /// Re-arms a valid durable checkpoint after its single keyed hook row has
    /// been reused by a later resume of the same conversation in another pane.
    ///
    /// Legacy Hermes approval callbacks also persisted the old pane's surface
    /// UUID as a running transport identity. That surface-scoped record remains
    /// available after the durable session row moves, so it can prove that the
    /// retired binding came from a failed legacy restore. The durable ID itself
    /// still has to exist in the same state database, while the surface UUID
    /// must not.
    private func detachedDurableResolution(
        state: HookStore,
        requestedSessionID: String,
        surfaceID: UUID,
        expectedWorkspaceID: UUID?,
        expectedWorkingDirectory: String?,
        displacedRecord: HookRecord?,
        environment: [String: String],
        databaseInspector: RecoveryDatabaseInspector
    ) -> Resolution {
        let stateDBPath = normalizedStateDBPath(
            HermesAgentSessionResolver.stateDBPath(env: environment)
        )
        let workingDirectory = normalized(expectedWorkingDirectory)
            .map { ($0 as NSString).standardizingPath }
            ?? displacedRecord.flatMap(normalizedWorkingDirectory)
        guard let workingDirectory else {
            return exactResolution(
                sessionID: requestedSessionID,
                environment: environment,
                databaseInspector: databaseInspector
            )
        }

        let surfaceTransportID = surfaceID.uuidString
        let candidates = state.sessions.values.filter { candidate in
            guard candidate.sessionId.caseInsensitiveCompare(requestedSessionID) != .orderedSame,
                  candidate.sessionId.caseInsensitiveCompare(surfaceTransportID) == .orderedSame,
                  record(
                      candidate,
                      belongsTo: surfaceID,
                      expectedWorkspaceID: expectedWorkspaceID
                  ),
                  recordReportsRunningLifecycle(candidate),
                  recordHasProcessGeneration(candidate),
                  recordMatchesWorkingDirectory(candidate, workingDirectory),
                  normalizedStateDBPath(HermesAgentSessionResolver.stateDBPath(
                      env: stateEnvironment(base: environment, launchCommand: candidate.launchCommand)
                  )) == stateDBPath else {
                return false
            }
            return true
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return exactResolution(
                sessionID: requestedSessionID,
                environment: environment,
                databaseInspector: databaseInspector
            )
        }

        guard let inspection = databaseInspector(
            [requestedSessionID, candidate.sessionId],
            nil,
            nil,
            nil,
            stateDBPath
        ) else {
            return .unavailable
        }
        guard inspection.existence(of: requestedSessionID) == .exists else {
            return .missing
        }
        guard inspection.existence(of: candidate.sessionId) == .missing else {
            return .valid
        }
        return .legacyRestore(Result(
            sessionID: requestedSessionID,
            launchCommand: candidate.launchCommand
        ))
    }

    private func exactResolution(
        sessionID: String,
        environment: [String: String],
        databaseInspector: RecoveryDatabaseInspector
    ) -> Resolution {
        let stateDBPath = normalizedStateDBPath(
            HermesAgentSessionResolver.stateDBPath(env: environment)
        )
        guard let inspection = databaseInspector(
            [sessionID],
            nil,
            nil,
            nil,
            stateDBPath
        ) else {
            return .unavailable
        }
        return inspection.existence(of: sessionID) == .exists ? .valid : .missing
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

    private func record(
        _ record: HookRecord,
        belongsTo surfaceID: UUID,
        expectedWorkspaceID: UUID?
    ) -> Bool {
        record.surfaceId.caseInsensitiveCompare(surfaceID.uuidString) == .orderedSame
            && (expectedWorkspaceID.map {
                record.workspaceId.caseInsensitiveCompare($0.uuidString) == .orderedSame
            } ?? true)
    }

    private func recordHasProcessGeneration(_ record: HookRecord) -> Bool {
        guard let pid = record.pid,
              pid > 0,
              let seconds = record.pidStartSeconds,
              seconds >= 0,
              let microseconds = record.pidStartMicroseconds,
              microseconds >= 0,
              microseconds < 1_000_000 else {
            return false
        }
        return true
    }

    private func recordReportsRunningLifecycle(_ record: HookRecord) -> Bool {
        normalized(record.runtimeStatus)?.lowercased() == "running"
            && normalized(record.agentLifecycle)?.lowercased() == "running"
    }

    private func recordsMatchWorkingDirectory(
        _ lhs: HookRecord,
        _ rhs: HookRecord
    ) -> Bool {
        guard let lhs = normalizedWorkingDirectory(lhs),
              let rhs = normalizedWorkingDirectory(rhs) else {
            return false
        }
        return lhs == rhs
    }

    private func recordMatchesWorkingDirectory(
        _ record: HookRecord,
        _ expectedWorkingDirectory: String
    ) -> Bool {
        normalizedWorkingDirectory(record) == expectedWorkingDirectory
    }

    private func normalizedWorkingDirectory(_ record: HookRecord) -> String? {
        guard let workingDirectory = normalized(record.cwd)
            ?? normalized(record.launchCommand?.workingDirectory) else {
            return nil
        }
        return (workingDirectory as NSString).standardizingPath
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
