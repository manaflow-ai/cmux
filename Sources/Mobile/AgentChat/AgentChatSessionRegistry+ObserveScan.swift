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
            Self.scanObservedAgentSessions(onlySurfaceIDs: scope.surfaceIDs)
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
    ) -> [ObservedAgentSession] {
        guard !Task.isCancelled else { return [] }
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: true,
            includeCMUXScope: true
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

    nonisolated static func allowsLaunchKindEnvironment(
        for process: CmuxTopProcessInfo,
        rootPIDs: Set<Int>,
        arguments: [String]?
    ) -> Bool {
        if rootPIDs.contains(process.pid) {
            return true
        }
        guard process.isTerminalForegroundProcessGroup,
              process.processGroupID == process.pid,
              let arguments else {
            return false
        }
        if CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: arguments,
            environment: [:]
        ) != nil {
            return true
        }
        return arguments.dropFirst().contains { argument in
            normalizedObserverValue(argument)?.contains("/.cmux-agent-wrapper/") == true
        }
    }

    nonisolated static func codingAgentDefinition(
        for process: CmuxTopProcessInfo,
        allowLaunchKindEnvironment: Bool,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let shouldReadDetails = CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        )
        if let direct = authoritativeCodingAgentDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: [],
            environment: [:],
            allowLaunchKindEnvironment: false
        ) {
            return direct
        }
        if !shouldReadDetails { return nil }
        guard let details = processArgumentsAndEnvironment(process.pid) else {
            return nil
        }
        return authoritativeCodingAgentDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: details.arguments,
            environment: details.environment,
            allowLaunchKindEnvironment: allowLaunchKindEnvironment
        )
    }

    private nonisolated static func authoritativeCodingAgentDefinition(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String],
        allowLaunchKindEnvironment: Bool
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let definitions = CmuxTaskManagerCodingAgentDefinition.builtIns
        if allowLaunchKindEnvironment,
           let launchKind = normalizedObserverValue(environment["CMUX_AGENT_LAUNCH_KIND"]),
           let def = definitions.first(where: { $0.launchKinds.contains(launchKind) }) {
            return def
        }
        let basenames = Set([processName, processPath, arguments.first].compactMap(observerBasename))
        if let def = definitions.first(where: { def in basenames.contains { def.directBasenames.contains($0) } }) {
            return def
        }
        guard let path = normalizedObserverValue(processPath) else { return nil }
        return definitions.first { def in
            def.argumentNeedles.contains { needle in
                guard needle.hasSuffix("/"),
                      let normalizedNeedle = normalizedObserverValue(needle) else { return false }
                return path.contains(normalizedNeedle)
            }
        }
    }

    private nonisolated static func observerBasename(_ value: String?) -> String? {
        normalizedObserverValue(value.map { ($0 as NSString).lastPathComponent })
    }

    private nonisolated static func normalizedObserverValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
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

    nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if ["--session-id", "--resume", "-r"].contains(arg),
               index + 1 < arguments.count,
               let id = sessionIDFromOptionValue(arguments[index + 1]) {
                return id
            }
            for prefix in ["--session-id=", "--resume=", "-r="] where arg.hasPrefix(prefix) {
                if let id = sessionIDFromOptionValue(String(arg.dropFirst(prefix.count))) {
                    return id
                }
            }
            index += 1
        }
        return nil
    }

    private nonisolated static func containsExplicitSessionOption(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument == "--session-id"
                || argument == "--resume"
                || argument == "-r"
                || argument.hasPrefix("--session-id=")
                || argument.hasPrefix("--resume=")
                || argument.hasPrefix("-r=")
        }
    }
    nonisolated static func containsClaudeForkSessionOption(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            let value = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == "--fork-session" || value.hasPrefix("--fork-session=")
        }
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
