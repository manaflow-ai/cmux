import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

enum AgentChatObservationScope: Equatable, Sendable {
    case all
    case surfaces(Set<UUID>)

    init(surfaceIDs: Set<UUID>?) {
        if let surfaceIDs {
            self = .surfaces(surfaceIDs)
        } else {
            self = .all
        }
    }

    var surfaceIDs: Set<UUID>? {
        switch self {
        case .all:
            return nil
        case .surfaces(let ids):
            return ids
        }
    }

    func covers(_ requested: AgentChatObservationScope) -> Bool {
        switch (self, requested) {
        case (.all, _):
            return true
        case (.surfaces, .all):
            return false
        case (.surfaces(let current), .surfaces(let requestedIDs)):
            return current.isSuperset(of: requestedIDs)
        }
    }
}

struct AgentChatObservationHandle: Sendable {
    let id: UUID
    let task: Task<Void, Never>
}

struct AgentChatObservationInFlight {
    let id: UUID
    let scope: AgentChatObservationScope
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var handle: AgentChatObservationHandle {
        AgentChatObservationHandle(id: id, task: task)
    }
}

extension AgentChatSessionRegistry {
    func reviveEndedObservedSessionIfNeeded(
        current: AgentChatSessionRecord,
        observed session: ObservedAgentSession,
        now: Date
    ) -> Bool {
        guard observationCanReviveEndedSession(current: current, observedAt: session.sampledAt) else {
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
              observationCanReviveEndedSession(current: current, observedAt: session.sampledAt),
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

    func scheduleAgentProcessObservation() {
        _ = observeAgentProcessesTask(scope: .all, force: false)
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
            inFlight.waiters[waiterID] = continuation
            observeInFlight = inFlight
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard let self,
                      var current = self.observeInFlight,
                      current.id == observation.id,
                      current.waiters.removeValue(forKey: waiterID) != nil else { return }
                self.observeInFlight = current
                continuation.resume(returning: false)
            }
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
        for continuation in inFlight.waiters.values {
            continuation.resume(returning: value)
        }
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
        let task = Task { @MainActor [weak self] in
            let observed = await Task.detached {
                Self.scanObservedAgentSessions(onlySurfaceIDs: scope.surfaceIDs)
            }.value
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
    ) -> [ObservedAgentSession] {
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: true,
            includeCMUXScope: true
        )
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
        var result: [ObservedAgentSession] = []
        var seen = Set<String>()
        for process in snapshot.cmuxScopedProcesses() {
            var details: CmuxTopProcessArguments?
            func loadDetails() -> CmuxTopProcessArguments? {
                if details == nil {
                    details = processArgumentsAndEnvironment(process.pid)
                }
                return details
            }
            guard process.isTerminalForegroundProcessGroup,
                  let surfaceID = process.cmuxSurfaceID,
                  surfaceIDs.map({ $0.contains(surfaceID) }) ?? true,
                  let def = codingAgentDefinition(
                      for: process,
                      processArgumentsAndEnvironment: { _ in loadDetails() }
                  ),
                  def.id == "codex" || def.id == "claude" else { continue }
            var sessionID: String?
            var transcriptPath: String?
            if def.id == "codex", let rollout = codexRolloutPath(process.pid) {
                transcriptPath = rollout
                sessionID = firstUUIDLike(in: (rollout as NSString).lastPathComponent)
            }
            if def.id == "claude",
               let envSessionID = loadDetails()?.environment["CLAUDE_CODE_SESSION_ID"],
               let id = firstUUIDLike(in: envSessionID) {
                sessionID = id
            }
            if sessionID == nil,
               let argv = loadDetails()?.arguments {
                sessionID = sessionIDFromArguments(argv)
            }
            guard let resolved = sessionID, !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            result.append(ObservedAgentSession(
                sessionID: resolved,
                agentKind: ChatAgentKind(source: def.id),
                surfaceID: surfaceID.uuidString,
                workspaceID: process.cmuxWorkspaceID?.uuidString,
                pid: process.pid,
                workingDirectory: observedWorkingDirectory(details?.environment),
                transcriptPath: transcriptPath,
                sampledAt: snapshot.sampledAt
            ))
        }
        return result
    }

    nonisolated static func codingAgentDefinition(
        for process: CmuxTopProcessInfo,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let shouldReadDetails = CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        )
        if let direct = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: [],
            environment: [:]
        ) {
            return direct
        }
        if !shouldReadDetails {
            return nil
        }
        guard let details = processArgumentsAndEnvironment(process.pid) else {
            return nil
        }
        return CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: details.arguments,
            environment: [:]
        )
    }

    private nonisolated static func observedWorkingDirectory(_ environment: [String: String]?) -> String? {
        guard let environment else { return nil }
        for key in ["CMUX_AGENT_LAUNCH_CWD", "PWD"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func pendingClaudeSessionID(surfaceID: String) -> String {
        "pending-claude-\(surfaceID)"
    }

    nonisolated static func pendingClaudeSessionID(surfaceID: String, pid: Int) -> String {
        "pending-claude-\(surfaceID)-pid-\(pid)"
    }

    nonisolated static func isPendingClaudeSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix("pending-claude-")
    }

    private func endedPendingClaudeSessionHasHistoryIdentity(_ record: AgentChatSessionRecord) -> Bool {
        record.transcriptPath != nil || record.hookStoreSessionID != nil
    }

    private func observationCanReviveEndedSession(
        current: AgentChatSessionRecord,
        observedAt: Date
    ) -> Bool {
        guard current.state == .ended else {
            return false
        }
        return observedAt >= (current.endedAt ?? current.lastActivityAt)
    }

    /// Extracts a session id from an agent's argv (`--session-id <id>`,
    /// `--session-id=<id>`, `--resume <id>`, `--resume=<id>`, `-r <id>`).
    nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if (arg == "--session-id" || arg == "--resume" || arg == "-r"),
               index + 1 < arguments.count,
               let id = sessionIDFromOptionValue(arguments[index + 1]) {
                return id
            }
            if arg.hasPrefix("--session-id="),
               let id = sessionIDFromOptionValue(String(arg.dropFirst("--session-id=".count))) {
                return id
            }
            if arg.hasPrefix("--resume="),
               let id = sessionIDFromOptionValue(String(arg.dropFirst("--resume=".count))) {
                return id
            }
            if arg.hasPrefix("-r="),
               let id = sessionIDFromOptionValue(String(arg.dropFirst("-r=".count))) {
                return id
            }
            index += 1
        }
        return nil
    }

    private nonisolated static func sessionIDFromOptionValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("-") else { return nil }
        return firstUUIDLike(in: trimmed)
    }

    /// libproc: the path of a `~/.codex/sessions/**/rollout-*.jsonl` the process
    /// holds open (codex keeps its rollout open for writing), or nil.
    nonisolated static func openCodexRolloutPath(pid: Int) -> String? {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return nil }
        let actual = Int(used) / MemoryLayout<proc_fdinfo>.stride
        for index in 0..<min(actual, fds.count) {
            guard fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fds[index].proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") {
                return path
            }
        }
        return nil
    }

    private nonisolated static let uuidLikeRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    /// The first UUID-shaped substring (matches both standard UUIDs and codex's
    /// UUIDv7 rollout ids), or nil.
    nonisolated static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else { return nil }
        return String(string[matchRange])
    }
}
