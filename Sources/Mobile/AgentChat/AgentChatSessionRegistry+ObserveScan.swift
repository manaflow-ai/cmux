import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

extension AgentChatSessionRegistry {
    func reviveEndedObservedSessionIfNeeded(
        current: AgentChatSessionRecord,
        observed session: ObservedAgentSession,
        now: Date
    ) -> Bool {
        guard observationCanReviveEndedSession(current: current, observed: session) else {
            return false
        }
        if reviveEndedPendingClaudeSessionIfNeeded(current: current, observed: session, now: now) {
            return true
        }
        update(sessionID: current.sessionID) { record in
            record.workspaceID = session.workspaceID ?? record.workspaceID
            record.surfaceID = session.surfaceID
            record.workingDirectory = session.workingDirectory ?? record.workingDirectory
            record.transcriptPath = session.transcriptPath ?? record.transcriptPath
            record.pid = session.pid
            record.state = .idle
            record.lastActivityAt = now
        }
        return true
    }

    func reviveEndedPendingClaudeSessionIfNeeded(
        current: AgentChatSessionRecord,
        observed session: ObservedAgentSession,
        now: Date
    ) -> Bool {
        guard current.state == .ended,
              session.agentKind == .claude,
              Self.isPendingClaudeSessionID(current.sessionID),
              !endedPendingClaudeSessionHasHistoryIdentity(current) else {
            return false
        }
        update(sessionID: current.sessionID) { record in
            record.workspaceID = session.workspaceID ?? record.workspaceID
            record.surfaceID = session.surfaceID
            record.workingDirectory = session.workingDirectory ?? record.workingDirectory
            record.transcriptPath = session.transcriptPath ?? record.transcriptPath
            record.pid = session.pid
            record.state = .idle
            record.lastActivityAt = now
        }
        return true
    }

    func observedClaudeSessionID(
        canonicalSessionID: String,
        observed session: ObservedAgentSession
    ) -> String {
        guard let current = record(sessionID: canonicalSessionID),
              current.state == .ended,
              endedPendingClaudeSessionHasHistoryIdentity(current),
              observationCanReviveEndedSession(current: current, observed: session),
              session.agentKind == .claude,
              Self.isPendingClaudeSessionID(canonicalSessionID) else {
            return canonicalSessionID
        }
        return Self.pendingClaudeSessionID(surfaceID: session.surfaceID, pid: session.pid)
    }

    func observeAgentProcesses() async {
        if let observation = observeAgentProcessesTask(scope: .all, force: true) {
            await observation.task.value
        }
    }

    func observeAgentProcessesForListing(surfaceIDs: Set<UUID>?, waitUpTo timeout: Duration) async -> Bool {
        if let surfaceIDs, surfaceIDs.isEmpty {
            return true
        }
        let scope = AgentChatObservationScope(surfaceIDs: surfaceIDs)
        let force = surfaceIDs != nil
        guard let observation = observeAgentProcessesTask(scope: scope, force: force) else {
            return true
        }
        return await waitForObservation(observation, upTo: timeout)
    }

    func waitForObservation(_ observation: AgentChatObservationHandle, upTo timeout: Duration) async -> Bool {
        guard observeInFlight?.id == observation.id else {
            return true
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            guard var inFlight = observeInFlight, inFlight.id == observation.id else {
                continuation.resume(returning: true)
                return
            }
            let timeoutSeconds = Self.timeInterval(for: timeout)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self, weak timer] in
                Task { @MainActor [weak self, weak timer] in
                    guard let self,
                          var current = self.observeInFlight,
                          current.id == observation.id,
                          let waiter = current.waiters.removeValue(forKey: waiterID) else { return }
                    timer?.cancel()
                    waiter.timer?.cancel()
                    self.observeInFlight = current
                    waiter.continuation.resume(returning: false)
                }
            }
            inFlight.waiters[waiterID] = (continuation: continuation, timer: timer)
            observeInFlight = inFlight
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.resume()
        }
    }

    private func finishAgentProcessObservation(id: UUID) {
        guard let inFlight = observeInFlight, inFlight.id == id else {
            return
        }
        observeInFlight = nil
        resumeAgentProcessObservationWaiters(inFlight, returning: true)
    }

    func replaceAgentProcessObservation(with inFlight: AgentChatObservationInFlight) {
        if let current = observeInFlight {
            current.task.cancel()
            observeInFlight = nil
            resumeAgentProcessObservationWaiters(current, returning: false)
        }
        observeInFlight = inFlight
    }

    private func resumeAgentProcessObservationWaiters(
        _ inFlight: AgentChatObservationInFlight,
        returning value: Bool
    ) {
        for waiter in inFlight.waiters.values {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: value)
        }
    }

    private nonisolated static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = TimeInterval(components.seconds)
        let fractional = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, seconds + fractional)
    }

    private func observeAgentProcessesTask(scope: AgentChatObservationScope, force: Bool) -> AgentChatObservationHandle? {
        if let inFlight = observeInFlight,
           inFlight.scope.covers(scope) {
            return inFlight.handle
        }
        if !force,
           let observeLastStartedAt {
            let elapsed = Date().timeIntervalSince(observeLastStartedAt)
            if elapsed < Self.observeThrottleInterval {
                return nil
            }
        }
        observeLastStartedAt = Date()
        let id = UUID()
        let scanTask = Task.detached {
            await Self.scanObservedAgentSessions(onlySurfaceIDs: scope.surfaceIDs)
        }
        let task = Task { @MainActor [weak self] in
            let observed = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.observeInFlight?.id == id else { return }
            self.applyObservedSessions(observed)
            self.finishAgentProcessObservation(id: id)
        }
        let inFlight = AgentChatObservationInFlight(id: id, scope: scope, task: task)
        replaceAgentProcessObservation(with: inFlight)
        return inFlight.handle
    }

    /// Off-main: one entry per distinct live codex/claude session under any cmux
    /// surface, identity resolved without hooks.
    private nonisolated static func scanObservedAgentSessions(
        onlySurfaceIDs surfaceIDs: Set<UUID>? = nil
    ) async -> [ObservedAgentSession] {
        guard !Task.isCancelled else { return [] }
        let snapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
            requirements: [.processDetails, .cmuxScope],
            maximumAge: 1,
            consumer: .sharedLiveAgentIndex
        )
        guard !Task.isCancelled else { return [] }
        return scanObservedAgentSessions(
            in: snapshot,
            onlySurfaceIDs: surfaceIDs,
            processArgumentsAndEnvironment: CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:),
            codexRolloutPath: openCodexRolloutPath(pid:)
        )
    }

    nonisolated static func scanObservedAgentSessions(
        in snapshot: CmuxTopProcessSnapshot,
        onlySurfaceIDs surfaceIDs: Set<UUID>? = nil,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?,
        codexRolloutPath: (Int) -> String?
    ) -> [ObservedAgentSession] {
        struct Candidate {
            let session: ObservedAgentSession
            let depth: Int
        }

        var candidateBySessionID: [String: Candidate] = [:]
        var rootPIDsBySurfaceID: [UUID: Set<Int>] = [:]
        func rootPIDs(for surfaceID: UUID) -> Set<Int> {
            if let cached = rootPIDsBySurfaceID[surfaceID] { return cached }
            let roots = cmuxSurfaceRootPIDs(surfaceID: surfaceID, snapshot: snapshot)
            rootPIDsBySurfaceID[surfaceID] = roots
            return roots
        }
        for process in snapshot.cmuxScopedProcesses() {
            if Task.isCancelled { return [] }
            var details: CmuxTopProcessArguments?
            func loadDetails() -> CmuxTopProcessArguments? {
                if details == nil {
                    details = processArgumentsAndEnvironment(process.pid)
                }
                return details
            }
            guard process.isTerminalForegroundProcessGroup,
                  let surfaceID = process.cmuxSurfaceID,
                  surfaceIDs.map({ $0.contains(surfaceID) }) ?? true else { continue }
            let rootPIDs = rootPIDs(for: surfaceID)
            guard let def = codingAgentDefinition(
                for: process,
                allowLaunchKindEnvironment: allowsLaunchKindEnvironment(
                    for: process,
                    rootPIDs: rootPIDs,
                    arguments: rootPIDs.contains(process.pid) ? nil : loadDetails()?.arguments
                ),
                processArgumentsAndEnvironment: { _ in loadDetails() }
            ),
            def.id == "codex" || def.id == "claude" else { continue }
            let loadedDetails = loadDetails()
            let argv = loadedDetails?.arguments
            let isClaudeForkLaunch = def.id == "claude" && argv.map(Self.containsClaudeForkSessionOption(_:)) == true
            var sessionID: String?
            var transcriptPath: String?
            if def.id == "codex", let rollout = codexRolloutPath(process.pid) {
                transcriptPath = rollout
                sessionID = firstUUIDLike(in: (rollout as NSString).lastPathComponent)
            }
            if def.id == "claude",
               !isClaudeForkLaunch,
               let envSessionID = loadedDetails?.environment["CLAUDE_CODE_SESSION_ID"],
               let id = firstUUIDLike(in: envSessionID) {
                sessionID = id
            }
            if sessionID == nil, let argv, !isClaudeForkLaunch {
                sessionID = sessionIDFromArguments(argv)
            }
            let explicitSessionOption = !isClaudeForkLaunch
                && (argv.map(containsExplicitSessionOption(_:)) ?? false)
            guard let resolved = sessionID ?? (def.id == "claude" && !explicitSessionOption ? pendingClaudeSessionID(surfaceID: surfaceID.uuidString) : nil) else { continue }
            let candidate = Candidate(
                session: ObservedAgentSession(
                    sessionID: resolved,
                    agentKind: ChatAgentKind(source: def.id),
                    surfaceID: surfaceID.uuidString,
                    workspaceID: process.cmuxWorkspaceID?.uuidString,
                    pid: process.pid,
                    workingDirectory: observedWorkingDirectory(details?.environment),
                    transcriptPath: transcriptPath,
                    sampledAt: snapshot.sampledAt
                ),
                depth: processTreeDepth(pid: process.pid, rootPIDs: rootPIDs, snapshot: snapshot)
            )
            if let current = candidateBySessionID[resolved] {
                let preferred = preferredLiveAgentPID(
                    current: (current.session.pid, current.depth),
                    candidate: (candidate.session.pid, candidate.depth)
                )
                if preferred.pid == candidate.session.pid {
                    candidateBySessionID[resolved] = candidate
                }
            } else {
                candidateBySessionID[resolved] = candidate
            }
        }
        return candidateBySessionID.values.map(\.session).sorted { $0.pid < $1.pid }
    }

    private func endedPendingClaudeSessionHasHistoryIdentity(_ record: AgentChatSessionRecord) -> Bool {
        record.transcriptPath != nil || record.hookStoreSessionID != nil
    }

    private func observationCanReviveEndedSession(
        current: AgentChatSessionRecord,
        observed session: ObservedAgentSession
    ) -> Bool {
        guard current.state == .ended, current.pid != session.pid else {
            return false
        }
        return session.sampledAt >= (current.endedAt ?? current.lastActivityAt)
    }

}
