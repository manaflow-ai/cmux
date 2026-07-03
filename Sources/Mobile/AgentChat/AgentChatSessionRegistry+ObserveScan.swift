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

private final class AgentChatObservationWaitResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, returning value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
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
        if let task = observeAgentProcessesTask(scope: .all, force: true) {
            await task.value
        }
    }

    func observeAgentProcessesForListing(surfaceIDs: Set<UUID>?, waitUpTo timeout: Duration) async -> Bool {
        if let surfaceIDs, surfaceIDs.isEmpty {
            return true
        }
        let scope = AgentChatObservationScope(surfaceIDs: surfaceIDs)
        let force = surfaceIDs != nil
        guard let task = observeAgentProcessesTask(scope: scope, force: force) else {
            return true
        }
        return await waitForObservation(task, upTo: timeout)
    }

    func scheduleAgentProcessObservation() {
        _ = observeAgentProcessesTask(scope: .all, force: false)
    }

    private func waitForObservation(_ task: Task<Void, Never>, upTo timeout: Duration) async -> Bool {
        await Self.waitForObservationTask(task, upTo: timeout)
    }

    nonisolated static func waitForObservationTask(_ task: Task<Void, Never>, upTo timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let resume = AgentChatObservationWaitResume()
            Task {
                await task.value
                resume.resume(continuation, returning: true)
            }
            Task {
                do {
                    try await Task.sleep(for: timeout)
                    resume.resume(continuation, returning: false)
                } catch {
                    resume.resume(continuation, returning: true)
                }
            }
        }
    }

    private func observeAgentProcessesTask(scope: AgentChatObservationScope, force: Bool) -> Task<Void, Never>? {
        if let inFlight = observeInFlight,
           inFlight.scope.covers(scope) {
            return inFlight.task
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
            guard let self else { return }
            self.applyObservedSessions(observed)
            if self.observeInFlight?.id == id {
                self.observeInFlight = nil
            }
        }
        observeInFlight = (id, scope, task)
        return task
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
            guard let surfaceID = process.cmuxSurfaceID,
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
            if sessionID == nil, def.id == "claude" {
                sessionID = pendingClaudeSessionID(surfaceID: surfaceID.uuidString)
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
    /// `--session-id=<id>`, `--resume <id>`, `--resume=<id>`).
    private nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--session-id" || arg == "--resume", index + 1 < arguments.count,
               let id = firstUUIDLike(in: arguments[index + 1]) {
                return id
            }
            if arg.hasPrefix("--session-id="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--session-id=".count))) {
                return id
            }
            if arg.hasPrefix("--resume="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--resume=".count))) {
                return id
            }
            index += 1
        }
        return nil
    }

    /// libproc: the path of a `~/.codex/sessions/**/rollout-*.jsonl` the process
    /// holds open (codex keeps its rollout open for writing), or nil.
    private nonisolated static func openCodexRolloutPath(pid: Int) -> String? {
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
    private nonisolated static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else { return nil }
        return String(string[matchRange])
    }
}
