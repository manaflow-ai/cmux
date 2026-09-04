import Darwin
import Foundation

/// One validated owner candidate collected while the shared Vault index loads.
struct LiveAgentSessionOwnerObservation: Sendable {
    let owner: LiveAgentSessionOwner

    static func validatingHookRecord(
        snapshot: SessionRestorableAgentSnapshot,
        record: RestorableAgentHookSessionRecord,
        workspaceID: UUID,
        surfaceID: UUID,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> Self? {
        guard let processID = record.pid,
              processID > 0,
              processID <= Int(Int32.max),
              let startSeconds = record.pidStartSeconds,
              let startMicroseconds = record.pidStartMicroseconds,
              startSeconds >= 0,
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
        guard processIdentityProvider(processID) == recordedIdentity,
              let process = processArgumentsProvider(processID),
              validator.currentProcess(
                  process,
                  matches: snapshot,
                  hermesSessionValidation: .currentHookRecord
              ) else {
            return nil
        }
        return Self(owner: LiveAgentSessionOwner(
            kind: snapshot.kind.rawValue,
            sessionID: snapshot.sessionId,
            processID: processID,
            processIdentity: recordedIdentity,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            observedAt: record.updatedAt,
            validationSnapshot: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
    }

    static func processDetected(
        snapshot: SessionRestorableAgentSnapshot,
        workspaceID: UUID,
        surfaceID: UUID,
        processIDs: Set<Int>,
        observedAt: TimeInterval,
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?,
        validator: CachedAgentProcessIdentityValidator
    ) -> [Self] {
        processIDs.compactMap { processID in
            guard let identity = processIdentityProvider(processID),
                  let process = processArgumentsProvider(processID),
                  validator.currentProcess(
                      process,
                      matches: snapshot,
                      hermesSessionValidation: .cachedSnapshot
                  ) else {
                return nil
            }
            return Self(owner: LiveAgentSessionOwner(
                kind: snapshot.kind.rawValue,
                sessionID: snapshot.sessionId,
                processID: processID,
                processIdentity: identity,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                observedAt: observedAt,
                validationSnapshot: snapshot,
                hermesSessionValidation: .cachedSnapshot
            ))
        }
    }
}
