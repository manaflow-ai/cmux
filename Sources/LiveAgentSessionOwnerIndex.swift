import Darwin
import Foundation

/// Session-keyed liveness facts used only for launch admission.
struct LiveAgentSessionOwnerIndex: Sendable {
    static let empty = Self(observations: [])

    private let ownersBySession: [LiveAgentSessionOwnerSessionKey: [LiveAgentSessionOwner]]

    init(observations: [LiveAgentSessionOwnerObservation]) {
        // A long-lived process can leave stale hook rows for older sessions.
        // One PID generation may own only its newest validated observation.
        var newestByProcessIdentity: [AgentPIDProcessIdentity: LiveAgentSessionOwner] = [:]
        for observation in observations {
            let candidate = observation.owner
            if let existing = newestByProcessIdentity[candidate.processIdentity],
               !Self.prefers(candidate, over: existing) {
                continue
            }
            newestByProcessIdentity[candidate.processIdentity] = candidate
        }

        var ownersBySession: [LiveAgentSessionOwnerSessionKey: [LiveAgentSessionOwner]] = [:]
        for owner in newestByProcessIdentity.values {
            ownersBySession[
                LiveAgentSessionOwnerSessionKey(kind: owner.kind, sessionID: owner.sessionID),
                default: []
            ].append(owner)
        }
        // Keep candidates unsorted. Admission needs one preferred live owner,
        // not an ordered history; selecting it with a linear reduction avoids
        // turning a large stale hook store into an O(n log n) restore pause.
        self.ownersBySession = ownersBySession
    }

    func owner(
        kind: String,
        sessionID: String,
        revalidateProcessEvidence: Bool = true,
        processArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)? = nil,
        processPresenceProvider: ((Int) -> PIDPresence)? = nil,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        }
    ) -> LiveAgentSessionOwner? {
        let owners = ownersBySession[LiveAgentSessionOwnerSessionKey(kind: kind, sessionID: sessionID)] ?? []
        let candidates = revalidateProcessEvidence
            ? owners.filter { owner in
                guard processIdentityProvider(owner.processID) == owner.processIdentity else {
                    return false
                }
                guard let processArgumentsProvider else { return true }
                guard let process = processArgumentsProvider(owner.processID) else {
                    // A matching process generation with temporarily unreadable
                    // argv is still safer to treat as owned than to launch a
                    // duplicate. If a presence probe proves ESRCH, let the
                    // restore proceed instead.
                    return processPresenceProvider?(owner.processID) != .absent
                }
                // Process identity and argv are separate observations. Recheck
                // the generation after argv inspection so PID reuse between the
                // two reads cannot bind a new process to the old owner.
                guard processIdentityProvider(owner.processID) == owner.processIdentity else {
                    return false
                }
                return CachedAgentProcessIdentityValidator().currentProcess(
                    process,
                    matches: owner.validationSnapshot,
                    hermesSessionValidation: owner.hermesSessionValidation
                )
            }
            : owners
        return Self.preferredOwner(in: candidates)
    }

    private static func preferredOwner(
        in owners: [LiveAgentSessionOwner]
    ) -> LiveAgentSessionOwner? {
        owners.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            return prefers(candidate, over: current) ? candidate : current
        }
    }

    var fingerprint: Set<String> {
        Set(ownersBySession.values.flatMap { owners in
            owners.map { owner in
                [
                    "session-owner",
                    owner.kind,
                    ManagedAgentSessionIdentity.canonicalSessionID(
                        kind: owner.kind,
                        sessionID: owner.sessionID
                    ),
                    String(owner.processID),
                    String(owner.processIdentity.startSeconds),
                    String(owner.processIdentity.startMicroseconds),
                ].joined(separator: "|")
            }
        })
    }

    func revalidated(
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity?
    ) -> Self {
        let validator = CachedAgentProcessIdentityValidator()
        return Self(observations: ownersBySession.values.flatMap { owners in
            owners.compactMap { owner in
                guard processIdentityProvider(owner.processID) == owner.processIdentity,
                      let process = processArgumentsProvider(owner.processID),
                      processIdentityProvider(owner.processID) == owner.processIdentity,
                      validator.currentProcess(
                          process,
                          matches: owner.validationSnapshot,
                          hermesSessionValidation: owner.hermesSessionValidation
                      ) else {
                    return nil
                }
                return LiveAgentSessionOwnerObservation(owner: owner)
            }
        })
    }

    private static func prefers(
        _ candidate: LiveAgentSessionOwner,
        over existing: LiveAgentSessionOwner
    ) -> Bool {
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt > existing.observedAt
        }
        let candidateIdentity = LiveAgentSessionOwnerSessionKey(kind: candidate.kind, sessionID: candidate.sessionID)
        let existingIdentity = LiveAgentSessionOwnerSessionKey(kind: existing.kind, sessionID: existing.sessionID)
        if candidateIdentity.kind != existingIdentity.kind {
            return candidateIdentity.kind > existingIdentity.kind
        }
        if candidateIdentity.sessionID != existingIdentity.sessionID {
            return candidateIdentity.sessionID > existingIdentity.sessionID
        }
        return candidate.processID > existing.processID
    }
}

extension RestorableAgentSessionIndex {
    /// Returns the live process that already owns this Vault session identity.
    func liveSessionOwner(
        kind: String,
        sessionID: String,
        revalidateProcessEvidence: Bool = true,
        processArgumentsProvider: ((Int) -> CmuxTopProcessArguments?)? = nil,
        processPresenceProvider: ((Int) -> PIDPresence)? = nil,
        processIdentityProvider: (Int) -> AgentPIDProcessIdentity? = {
            guard $0 > 0, $0 <= Int(Int32.max) else { return nil }
            return AgentPIDProcessIdentity(pid: pid_t($0))
        }
    ) -> LiveAgentSessionOwner? {
        liveSessionOwners.owner(
            kind: kind,
            sessionID: sessionID,
            revalidateProcessEvidence: revalidateProcessEvidence,
            processArgumentsProvider: processArgumentsProvider,
            processPresenceProvider: processPresenceProvider,
            processIdentityProvider: processIdentityProvider
        )
    }

    var liveSessionOwnerFingerprint: Set<String> {
        liveSessionOwners.fingerprint
    }
}
