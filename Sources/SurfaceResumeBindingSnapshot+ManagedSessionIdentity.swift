import Foundation

/// Compares the stable session identity published by agent hooks with the
/// representation produced by process discovery.
enum ManagedAgentSessionIdentity {
    /// Pi-compatible hooks publish a UUID, while `.piSessionFile` discovery
    /// resolves that UUID to the matching JSONL path. OMP uses the same store.
    private static let piSessionFileKinds: Set<String> = ["pi", "omp"]

    static func sessionIDsMatch(
        kind: String,
        lhs: String,
        rhs: String
    ) -> Bool {
        let normalizedLHS = normalized(lhs)
        let normalizedRHS = normalized(rhs)
        guard normalizedLHS != normalizedRHS else { return true }
        guard piSessionFileKinds.contains(normalized(kind)),
              let lhsUUID = piSessionUUID(from: normalizedLHS),
              let rhsUUID = piSessionUUID(from: normalizedRHS) else {
            return false
        }
        return lhsUUID == rhsUUID
    }

    static func canonicalSessionID(kind: String, sessionID: String) -> String {
        let normalizedSessionID = normalized(sessionID)
        guard piSessionFileKinds.contains(normalized(kind)),
              let uuid = piSessionUUID(from: normalizedSessionID) else {
            return normalizedSessionID
        }
        return uuid.uuidString.lowercased()
    }

    private static func piSessionUUID(from value: String) -> UUID? {
        if let uuid = UUID(uuidString: value) {
            return uuid
        }
        let filename = (value as NSString).lastPathComponent
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        if let uuid = UUID(uuidString: stem) {
            return uuid
        }
        guard let separator = stem.lastIndex(of: "_") else { return nil }
        return UUID(uuidString: String(stem[stem.index(after: separator)...]))
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension SurfaceResumeBindingSnapshot {
    /// Maximum time a CLI restore may hold an in-memory binding claim while
    /// handing control to the restored process.
    static let restoreClaimTTL: TimeInterval = 60

    var hasCompleteManagedSessionIdentity: Bool {
        managedSessionIdentity != nil
    }

    func isSameManagedSession(as other: SurfaceResumeBindingSnapshot) -> Bool {
        guard let identity = managedSessionIdentity,
              let otherIdentity = other.managedSessionIdentity else {
            return false
        }
        return identity.kind == otherIdentity.kind &&
            ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: identity.kind,
                lhs: identity.checkpointId,
                rhs: otherIdentity.checkpointId
            )
    }

    /// Whether an incoming hook refresh belongs to a claimed restore session.
    ///
    /// A same-session refresh consumes the claim; a different checkpoint or
    /// kind remains blocked until the claim expires or is explicitly cleared.
    func acceptsRestoreBindingClaim(
        from incoming: SurfaceResumeBindingSnapshot
    ) -> Bool {
        isAgentHookBinding
            && incoming.isAgentHookBinding
            && isSameManagedSession(as: incoming)
    }

    /// Projects an authoritative agent-hook binding into the structured
    /// session snapshot used by close history and workspace restore. A new
    /// checkpoint may reuse only kind-level registration metadata from the
    /// previous snapshot; cwd, launch capture, permission mode, and identity
    /// must come from the new binding so a fork cannot retain its parent.
    func managedRestorableAgentSnapshot(
        replacing previous: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        guard let identity = managedSessionIdentity else { return nil }
        let previousForKind = previous.flatMap {
            $0.kind.rawValue == identity.kind ? $0 : nil
        }
        guard let kind = RestorableAgentKind(
            persistedRawValue: identity.kind,
            registration: previousForKind?.registration
        ) else {
            return nil
        }
        let continuesPreviousSession = previousForKind.map {
            ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: identity.kind,
                lhs: $0.sessionId,
                rhs: identity.checkpointId
            )
        } == true
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: identity.checkpointId,
            workingDirectory: cwd
                ?? launchCommand?.workingDirectory
                ?? (continuesPreviousSession ? previousForKind?.workingDirectory : nil),
            launchCommand: launchCommand
                ?? (continuesPreviousSession ? previousForKind?.launchCommand : nil),
            registration: previousForKind?.registration,
            permissionMode: permissionMode
                ?? (continuesPreviousSession ? previousForKind?.permissionMode : nil),
            restoreWorkingDirectorySelection: restoreWorkingDirectorySelection
                ?? (continuesPreviousSession ? previousForKind?.restoreWorkingDirectorySelection : nil)
        )
    }

    private var managedSessionIdentity: (kind: String, checkpointId: String)? {
        guard source == "agent-hook",
              let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty,
              let checkpointId = checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointId.isEmpty else {
            return nil
        }
        return (kind, checkpointId)
    }
}
