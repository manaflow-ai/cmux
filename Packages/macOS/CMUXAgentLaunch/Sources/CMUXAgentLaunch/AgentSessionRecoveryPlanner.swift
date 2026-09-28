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
    public var updatedAt: Date

    public init(
        kind: String,
        sessionId: String,
        workspaceId: String?,
        cwd: String?,
        launchCommand: AgentLaunchCommand?,
        pid: Int?,
        pidStartSeconds: Int64? = nil,
        updatedAt: Date
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.launchCommand = launchCommand
        self.pid = pid
        self.pidStartSeconds = pidStartSeconds
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
    public var lastActivity: Date

    public init(
        kind: String,
        sessionId: String,
        workspaceId: String?,
        cwd: String?,
        launchCommand: AgentLaunchCommand?,
        lastActivity: Date
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.launchCommand = launchCommand
        self.lastActivity = lastActivity
    }

    /// Resume argv through the recorded outer launcher, or nil when none was
    /// recorded (callers then use the kind's normal resume command). The
    /// agent's own resume arguments, including preserved flags such as the
    /// permission mode or model, follow the launcher in place of the agent
    /// executable.
    ///
    /// Returns nil, deferring to the normal resume command, when:
    /// - a launcher the user declared in `agents.launchers`
    ///   (``AgentLaunchCommand/externalLauncher``) is recorded: the normal
    ///   resume command already re-supplies it;
    /// - the launch is a proven Subrouter-routed Claude launch: the normal
    ///   restore path owns that route (fresh private settings, environment,
    ///   and the account pin carried from this prefix);
    /// - the prefix could replay the old session (see
    ///   ``AgentLauncherPrefix/isReplayable(_:)``).
    ///
    /// Settings files that no longer exist (a launcher's per-launch temporary
    /// `--settings`) are dropped so the agent can start.
    public var launcherResumeArguments: [String]? {
        launcherResumeArguments(isReadableFile: { FileManager.default.isReadableFile(atPath: $0) })
    }

    func launcherResumeArguments(isReadableFile: @escaping (String) -> Bool) -> [String]? {
        guard let launchCommand,
              launchCommand.externalLauncher == nil,
              let prefix = launchCommand.launcherPrefix,
              AgentLauncherPrefix.isReplayable(prefix) else {
            return nil
        }
        let subrouter = SubrouterClaudeResumeRouting()
        if kind == "claude",
           subrouter.provesRoutedLaunch(launcher: launchCommand.launcher, environment: launchCommand.environment) {
            return nil
        }
        guard var agentArguments = AgentResumeArgv().builtInKind(
            kind: kind,
            sessionId: sessionId,
            executablePath: launchCommand.executablePath,
            arguments: launchCommand.arguments
        ) else {
            return nil
        }
        if kind == "claude" {
            agentArguments = ClaudeRestoreSettingsPathFilter(
                isReadableFile: isReadableFile,
                workingDirectory: cwd
            ).removingUnreadableSettingsPaths(
                from: subrouter.removingPrivateSettingsArguments(from: agentArguments)
            )
        }
        guard !agentArguments.isEmpty else { return nil }
        return prefix + agentArguments.dropFirst()
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
                lastActivity: session.lastOccurredAt
            ))
        }
        return result
    }
}
