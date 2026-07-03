import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

extension AgentChatSessionRegistry {
    /// Observe-floor liveness: the pid of a live foreground agent process
    /// matching `kind` under `surfaceID`'s process tree, or nil if none.
    ///
    /// A launcher or intermediate process (a subrouter like `sr`, a `node`
    /// shim) is NOT the agent; the real agent binary (e.g. `codex`, `claude`)
    /// appears deeper in the tree. So liveness must be judged from the whole
    /// foreground process tree under the surface, never from a single recorded
    /// pid that may be a launcher or from background descendants that would not
    /// receive terminal input. Nonisolated and snapshot-based so it runs off the
    /// main actor; callers hop back to the main actor to apply the result. The
    /// classifier is shared with observe-floor detection, so argv-hosted agents
    /// (`node .../claude-code`, `npx .../codex`) rebind the same way they are
    /// first discovered.
    nonisolated static func liveAgentPID(
        surfaceID: String,
        kind: ChatAgentKind,
        matchingSessionIDs expectedSessionIDs: Set<String>,
        allowUnidentifiedFallback: Bool = false
    ) -> Int? {
        guard !expectedSessionIDs.isEmpty else { return nil }
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
        return liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID,
            kind: kind,
            matchingSessionIDs: expectedSessionIDs,
            allowUnidentifiedFallback: allowUnidentifiedFallback,
            processArgumentsAndEnvironment: CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:)
        )
    }

    nonisolated static func liveAgentPID(
        in snapshot: CmuxTopProcessSnapshot,
        surfaceID: String,
        kind: ChatAgentKind,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID,
            kind: kind,
            matchingSessionIDs: nil,
            allowUnidentifiedFallback: false,
            processArgumentsAndEnvironment: processArgumentsAndEnvironment
        )
    }

    nonisolated static func liveAgentPID(
        in snapshot: CmuxTopProcessSnapshot,
        surfaceID: String,
        kind: ChatAgentKind,
        matchingSessionIDs expectedSessionIDs: Set<String>?,
        allowUnidentifiedFallback: Bool = false,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> Int? {
        guard let surfaceUUID = UUID(uuidString: surfaceID) else { return nil }
        let rootPIDs = snapshot.pids(forCMUXSurfaceID: surfaceUUID)
        guard !rootPIDs.isEmpty else { return nil }
        let wantedID = kind.sourceName
        var matchedPID: (pid: Int, depth: Int)?
        var unidentifiedFallbackPID: (pid: Int, depth: Int)?
        var sawMismatchedSessionIdentity = false
        let expandedPIDs = snapshot.expandedPIDs(rootPIDs: rootPIDs)
        for pid in expandedPIDs.sorted() {
            let depth = processTreeDepth(pid: pid, rootPIDs: rootPIDs, snapshot: snapshot)
            var details: CmuxTopProcessArguments?
            func loadDetails() -> CmuxTopProcessArguments? {
                if details == nil {
                    details = processArgumentsAndEnvironment(pid)
                }
                return details
            }
            guard let info = snapshot.process(pid: pid),
                  info.isTerminalForegroundProcessGroup,
                  let def = codingAgentDefinition(
                      for: info,
                      processArgumentsAndEnvironment: { _ in loadDetails() }
                  ),
                  def.id == wantedID else { continue }
            if let expectedSessionIDs {
                guard let candidateSessionID = observedSessionID(
                    agentID: def.id,
                    pid: pid,
                    details: loadDetails()
                ) else {
                    if allowUnidentifiedFallback {
                        unidentifiedFallbackPID = preferredLiveAgentPID(
                            current: unidentifiedFallbackPID,
                            candidate: (pid, depth)
                        )
                    }
                    continue
                }
                if expectedSessionIDs.contains(candidateSessionID) {
                    matchedPID = preferredLiveAgentPID(
                        current: matchedPID,
                        candidate: (pid, depth)
                    )
                } else {
                    sawMismatchedSessionIdentity = true
                }
                continue
            }
            matchedPID = preferredLiveAgentPID(
                current: matchedPID,
                candidate: (pid, depth)
            )
        }
        if let matchedPID {
            return matchedPID.pid
        }
        if !sawMismatchedSessionIdentity {
            return unidentifiedFallbackPID?.pid
        }
        return nil
    }

    private nonisolated static func preferredLiveAgentPID(
        current: (pid: Int, depth: Int)?,
        candidate: (pid: Int, depth: Int)
    ) -> (pid: Int, depth: Int) {
        guard let current else { return candidate }
        if candidate.depth > current.depth {
            return candidate
        }
        if candidate.depth == current.depth,
           candidate.pid > current.pid {
            return candidate
        }
        return current
    }

    private nonisolated static func processTreeDepth(
        pid: Int,
        rootPIDs: Set<Int>,
        snapshot: CmuxTopProcessSnapshot
    ) -> Int {
        guard pid > 0 else { return 0 }
        var currentPID = pid
        var depth = 0
        var visited: Set<Int> = []
        while !rootPIDs.contains(currentPID) {
            guard visited.insert(currentPID).inserted,
                  let parentPID = snapshot.process(pid: currentPID)?.parentPID,
                  parentPID > 0 else {
                break
            }
            currentPID = parentPID
            depth += 1
        }
        return depth
    }

    private nonisolated static func observedSessionID(
        agentID: String,
        pid: Int,
        details: CmuxTopProcessArguments?
    ) -> String? {
        if agentID == "codex",
           let rollout = openCodexRolloutPath(pid: pid) {
            return firstUUIDLike(in: (rollout as NSString).lastPathComponent)
        }
        if agentID == "claude",
           let envSessionID = details?.environment["CLAUDE_CODE_SESSION_ID"],
           let id = firstUUIDLike(in: envSessionID) {
            return id
        }
        if let argv = details?.arguments {
            return sessionIDFromArguments(argv)
        }
        return nil
    }
}
