import Foundation

/// The last agent-journal event seen for one agent session.
public struct AgentRecoveryJournalSession: Equatable, Sendable {
    public var sessionId: String
    /// The journal `source` slug (`claude`, `codex`).
    public var source: String
    public var lastOccurredAt: Date
    /// Whether the session's latest start was followed by an end event.
    public var hasEnded: Bool

    public init(sessionId: String, source: String, lastOccurredAt: Date, hasEnded: Bool) {
        self.sessionId = sessionId
        self.source = source
        self.lastOccurredAt = lastOccurredAt
        self.hasEnded = hasEnded
    }
}

/// What cmux recorded about an agent session's launch (from the hook store).
public struct AgentRecoveryLaunchRecord: Equatable, Sendable {
    public var kind: String
    public var sessionId: String
    public var workspaceId: String?
    public var cwd: String?
    public var launchCommand: AgentLaunchCommand?
    public var pid: Int?
    /// Start time of `pid`, so a reused pid does not look like the agent.
    public var pidStartSeconds: Int64?
    /// The permission mode the session was last observed in.
    public var permissionMode: String?
    public var updatedAt: Date

    public init(
        kind: String,
        sessionId: String,
        workspaceId: String?,
        cwd: String?,
        launchCommand: AgentLaunchCommand?,
        pid: Int?,
        pidStartSeconds: Int64? = nil,
        permissionMode: String? = nil,
        updatedAt: Date
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.launchCommand = launchCommand
        self.pid = pid
        self.pidStartSeconds = pidStartSeconds
        self.permissionMode = permissionMode
        self.updatedAt = updatedAt
    }
}

/// An agent session that was live when cmux last died and can be resumed.
public struct AgentRecoveryCandidate: Equatable, Sendable {
    public var kind: String
    public var sessionId: String
    public var workspaceId: String?
    public var cwd: String?
    public var launchCommand: AgentLaunchCommand?
    /// The permission mode the session was last observed in, reapplied on resume.
    public var permissionMode: String?
    public var lastActivity: Date

    public init(
        kind: String,
        sessionId: String,
        workspaceId: String?,
        cwd: String?,
        launchCommand: AgentLaunchCommand?,
        permissionMode: String? = nil,
        lastActivity: Date
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.launchCommand = launchCommand
        self.permissionMode = permissionMode
        self.lastActivity = lastActivity
    }

    /// Whether this is a proven Subrouter-routed Claude launch. Recovery
    /// resumes it through `cmux restore`, the path a normal restore takes,
    /// which resolves the routed launcher on `PATH` (falling back to a direct
    /// resume with a notice), authorizes the wrapper, and reapplies the
    /// observed permission mode.
    public var routesThroughSubrouter: Bool {
        kind == "claude" && SubrouterClaudeResumeRouting().provesRoutedLaunch(
            launcher: launchCommand?.launcher,
            environment: launchCommand?.environment
        )
    }

    /// Resume argv through the recorded outer launcher, or nil when none
    /// applies (callers then resume through `cmux restore`).
    ///
    /// The recorded launcher prefix runs in place of the agent executable,
    /// followed by the agent's own resume arguments and, for Claude, the
    /// observed permission mode.
    ///
    /// Returns nil for a proven routed launch (``routesThroughSubrouter``;
    /// `cmux restore` owns it), when a launcher the user declared in
    /// `agents.launchers` (``AgentLaunchCommand/externalLauncher``) is
    /// recorded (the normal resume re-supplies it), or when the prefix could
    /// replay the old session (see ``AgentLauncherPrefix/isReplayable(_:)``).
    /// Settings files that no longer exist are dropped so the agent can start.
    public var launcherResumeArguments: [String]? {
        launcherResumeArguments(isReadableFile: { FileManager.default.isReadableFile(atPath: $0) })
    }

    func launcherResumeArguments(isReadableFile: @escaping (String) -> Bool) -> [String]? {
        guard let launchCommand,
              launchCommand.externalLauncher == nil,
              !routesThroughSubrouter,
              let prefix = launchCommand.launcherPrefix,
              AgentLauncherPrefix.isReplayable(prefix),
              let agentArguments = AgentResumeArgv().builtInKind(
                kind: kind,
                sessionId: sessionId,
                executablePath: launchCommand.executablePath,
                arguments: launchCommand.arguments
              ), !agentArguments.isEmpty else {
            return nil
        }
        guard kind == "claude" else { return prefix + agentArguments.dropFirst() }
        // Applied to the agent's own argv so an option the launcher itself
        // takes can never be mistaken for the agent's permission flag.
        let agentOptions = AgentResumeArgv.claudeArgvApplyingObservedPermissionMode(
            SubrouterClaudeResumeRouting().removingPrivateSettingsArguments(from: agentArguments),
            observedPermissionMode: permissionMode
        ).dropFirst()
        let arguments = prefix + agentOptions
        let filtered = ClaudeRestoreSettingsPathFilter(
            isReadableFile: isReadableFile,
            workingDirectory: cwd
        ).removingUnreadableSettingsPaths(from: arguments)
        return filtered.isEmpty ? nil : filtered
    }
}

/// Finds agent sessions that were running when cmux died and are not open now.
///
/// A session is a candidate when the journal never recorded its end, its last
/// journal event is recent, cmux has a launch record for it, its recorded
/// process is gone, and no open panel already carries it (startup restore may
/// have resumed it from the snapshot).
public struct AgentSessionRecoveryPlanner: Sendable {
    public static let defaultMaximumAge: TimeInterval = 48 * 60 * 60

    /// Journal sessions older than this are never recovered.
    public let maximumAge: TimeInterval

    public init(maximumAge: TimeInterval = AgentSessionRecoveryPlanner.defaultMaximumAge) {
        self.maximumAge = maximumAge
    }

    public func candidates(
        journal: [AgentRecoveryJournalSession],
        records: [AgentRecoveryLaunchRecord],
        openSessionIds: Set<String>,
        isProcessAlive: (_ pid: Int, _ startSeconds: Int64?) -> Bool,
        now: Date
    ) -> [AgentRecoveryCandidate] {
        var recordsBySession: [String: AgentRecoveryLaunchRecord] = [:]
        for record in records {
            if let existing = recordsBySession[record.sessionId], existing.updatedAt >= record.updatedAt { continue }
            recordsBySession[record.sessionId] = record
        }
        var seen = Set<String>()
        var result: [AgentRecoveryCandidate] = []
        for session in journal.sorted(by: { $0.lastOccurredAt > $1.lastOccurredAt }) {
            guard !session.hasEnded,
                  now.timeIntervalSince(session.lastOccurredAt) <= maximumAge,
                  !openSessionIds.contains(session.sessionId),
                  seen.insert(session.sessionId).inserted,
                  let record = recordsBySession[session.sessionId],
                  record.kind == session.source else {
                continue
            }
            if let pid = record.pid, isProcessAlive(pid, record.pidStartSeconds) { continue }
            result.append(AgentRecoveryCandidate(
                kind: record.kind,
                sessionId: session.sessionId,
                workspaceId: record.workspaceId,
                cwd: record.cwd ?? record.launchCommand?.workingDirectory,
                launchCommand: record.launchCommand,
                permissionMode: record.permissionMode,
                lastActivity: session.lastOccurredAt
            ))
        }
        return result
    }
}

/// Which recovered sessions start right away and which wait until their
/// workspace is first shown.
///
/// A heavy user can have dozens of agents running when cmux dies, and starting
/// them all on relaunch spikes CPU and memory. Only a few start now: sessions
/// from a workspace on screen, then the most recently active. The rest open
/// their workspace now and resume on its first visit, the way startup restore
/// treats background workspaces.
///
/// A session resumed through its recorded launcher always starts now: its
/// launch claim is taken when the command is typed, and nothing would take it
/// on a later visit. Such sessions are rare.
public struct AgentRecoveryStartPlan: Equatable, Sendable {
    /// How many recovered sessions start right away by default.
    public static let defaultImmediateLimit = 3

    /// Sessions whose terminal starts now, in start order.
    public private(set) var startNow: [AgentRecoveryCandidate] = []
    /// Sessions whose workspace opens now and whose terminal starts on first visit.
    public private(set) var startOnVisit: [AgentRecoveryCandidate] = []

    /// - Parameters:
    ///   - candidates: The sessions to recover.
    ///   - visibleWorkspaceIds: Workspaces shown in a window right now.
    ///   - immediateLimit: How many sessions start right away.
    public init(
        candidates: [AgentRecoveryCandidate],
        visibleWorkspaceIds: Set<UUID> = [],
        immediateLimit: Int = AgentRecoveryStartPlan.defaultImmediateLimit
    ) {
        func isVisible(_ candidate: AgentRecoveryCandidate) -> Bool {
            candidate.workspaceId.flatMap(UUID.init(uuidString:)).map(visibleWorkspaceIds.contains) ?? false
        }
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let lhsVisible = isVisible(lhs.element)
            let rhsVisible = isVisible(rhs.element)
            if lhsVisible != rhsVisible { return lhsVisible }
            if lhs.element.lastActivity != rhs.element.lastActivity {
                return lhs.element.lastActivity > rhs.element.lastActivity
            }
            return lhs.offset < rhs.offset
        }
        for (_, candidate) in ranked {
            if startNow.count < immediateLimit || candidate.launcherResumeArguments != nil {
                startNow.append(candidate)
            } else {
                startOnVisit.append(candidate)
            }
        }
    }
}
