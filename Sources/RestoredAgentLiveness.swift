import Foundation

/// The one evaluator for "is this restored or hook-published agent still
/// running in its pane", shared by the workspace and Dock lifecycles.
///
/// Pi-compatible TUIs emit OSC 133 prompt and command marks while the agent
/// keeps running, so a shell-activity flip alone cannot prove that the agent
/// exited or was replaced (#12084). Evidence, cheapest first: the
/// hook-registered `<kind>.<session>` process whose start-time identity still
/// matches, the live agent index with revalidated process evidence, and the
/// pane's foreground process validated against the agent identity, which
/// covers the window before the session-start hook registers a PID.
struct RestoredAgentLiveness {
    /// The `<kind>.<session>` process a hook registered for the pane.
    struct RecordedProcess: Equatable {
        let pid: pid_t
        let identity: AgentPIDProcessIdentity?
    }

    /// Creates an evaluator with injectable process probes.
    init(
        currentProcessIdentity: @escaping (pid_t) -> AgentPIDProcessIdentity? = { AgentPIDProcessIdentity(pid: $0) },
        foregroundProcessArguments: @escaping (Int) -> CmuxTopProcessArguments? =
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for:)
    ) {
        self.currentProcessIdentity = currentProcessIdentity
        self.foregroundProcessArguments = foregroundProcessArguments
    }

    private let currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    private let foregroundProcessArguments: (Int) -> CmuxTopProcessArguments?

    /// The runtime PID key hooks register for `agent`'s session.
    static func pidKey(for agent: SessionRestorableAgentSnapshot) -> String {
        "\(agent.kind.rawValue).\(agent.sessionId)"
    }

    /// Whether `agent` verifiably still runs in `panelId`.
    ///
    /// - Parameters:
    ///   - recordedProcess: the hook-registered process for this session on
    ///     this pane, if any. Claude's key identifies only a panel, so it never
    ///     vouches for a session generation.
    ///   - liveIndex: the shared live agent index, if loaded.
    ///   - foregroundProcessID: the pane's foreground process.
    ///   - currentProcessIdentity: start-time identity for a PID that is alive.
    ///   - foregroundProcessArguments: argv and environment for the foreground
    ///     process.
    func hasLiveProcess(
        _ agent: SessionRestorableAgentSnapshot,
        workspaceId: UUID,
        panelId: UUID,
        recordedProcess: RecordedProcess?,
        liveIndex: RestorableAgentSessionIndex?,
        foregroundProcessID: Int?,
        currentProcessIdentity: ((pid_t) -> AgentPIDProcessIdentity?)? = nil,
        foregroundProcessArguments: ((Int) -> CmuxTopProcessArguments?)? = nil
    ) -> Bool {
        if agent.kind != .claude,
           let recordedProcess,
           recordedProcess.pid > 0,
           let identity = recordedProcess.identity,
           identity.pid == recordedProcess.pid,
           (currentProcessIdentity ?? self.currentProcessIdentity)(recordedProcess.pid) == identity {
            return true
        }
        if liveIndex?.hasCurrentLiveProcessForStablePanel(
            workspaceId: workspaceId,
            panelId: panelId,
            expectedKind: agent.kind.rawValue,
            expectedSessionId: agent.sessionId
        ) == true {
            return true
        }
        // A missing or reused recorded process does not authorize another
        // bare executable; the foreground validator requires this session ID.
        return RestoredAgentForegroundProcess.matches(
            agent,
            foregroundProcessID: foregroundProcessID,
            processArguments: foregroundProcessArguments ?? self.foregroundProcessArguments
        )
    }
}
