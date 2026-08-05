import CmuxAgentReplica

@MainActor
final class AgentGUIIncrementalState {
    private var sessionIDByProcess: [ObservedProcessKey: AgentSessionID] = [:]
    private var processKeyBySessionID: [AgentSessionID: ObservedProcessKey] = [:]
    private var liveSessionIDs: Set<AgentSessionID> = []
    private var recentSessionExpirations: [AgentSessionID: Int] = [:]
    private var latestRecentSessionExpiration = Int.min
    private var nonEndedSessionIDs: Set<AgentSessionID> = []

    var hasNonEndedSessions: Bool {
        !nonEndedSessionIDs.isEmpty
    }

    func sessionID(pid: Int32, startTick: Int) -> AgentSessionID? {
        sessionIDByProcess[ObservedProcessKey(pid: pid, startTick: startTick)]
    }

    func bindProcess(pid: Int32, startTick: Int, to sessionID: AgentSessionID) {
        let processKey = ObservedProcessKey(pid: pid, startTick: startTick)
        if let previousSessionID = sessionIDByProcess.updateValue(sessionID, forKey: processKey),
           previousSessionID != sessionID {
            processKeyBySessionID.removeValue(forKey: previousSessionID)
        }
        if let previousKey = processKeyBySessionID.updateValue(processKey, forKey: sessionID),
           previousKey != processKey {
            sessionIDByProcess.removeValue(forKey: previousKey)
        }
    }

    func updateSession(_ session: AgentSessionSnapshot) {
        let previousExpiration = recentSessionExpirations.removeValue(forKey: session.id)
        liveSessionIDs.remove(session.id)
        switch session.phase {
        case .working, .needsInput:
            liveSessionIDs.insert(session.id)
        case .idle, .starting, .unknown:
            let expiration = session.lastActivityHint + AgentGUIConstants.liveRecentActivityWindowMS
            recentSessionExpirations[session.id] = expiration
            latestRecentSessionExpiration = max(latestRecentSessionExpiration, expiration)
        case .ended:
            break
        }
        if session.phase == .ended {
            nonEndedSessionIDs.remove(session.id)
        } else {
            nonEndedSessionIDs.insert(session.id)
        }
        if previousExpiration == latestRecentSessionExpiration,
           recentSessionExpirations[session.id] != previousExpiration {
            recomputeLatestRecentSessionExpiration()
        }
    }

    func removeSession(_ sessionID: AgentSessionID) {
        liveSessionIDs.remove(sessionID)
        nonEndedSessionIDs.remove(sessionID)
        let removedExpiration = recentSessionExpirations.removeValue(forKey: sessionID)
        if removedExpiration == latestRecentSessionExpiration {
            recomputeLatestRecentSessionExpiration()
        }
        guard let processKey = processKeyBySessionID.removeValue(forKey: sessionID) else { return }
        sessionIDByProcess.removeValue(forKey: processKey)
    }

    func hasLiveOrRecentlyActiveSession(at tick: Int) -> Bool {
        !liveSessionIDs.isEmpty || latestRecentSessionExpiration > tick
    }

    private func recomputeLatestRecentSessionExpiration() {
        latestRecentSessionExpiration = recentSessionExpirations.values.max() ?? Int.min
    }

    private struct ObservedProcessKey: Hashable {
        let pid: Int32
        let startTick: Int
    }
}
