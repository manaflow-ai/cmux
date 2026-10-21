import Foundation

/// Defines which agent hook events may use asynchronous queued delivery.
///
/// Lifecycle and status events are safe for every agent because their output
/// does not affect the agent's next decision. Wrapper-specific auxiliary
/// events remain explicitly scoped to the wrappers that own their contracts.
public struct AgentHookDeliveryPolicy: Sendable {
    /// Marks local hook routing that was resolved before queue admission.
    public static let routeSnapshotEnvironmentKey =
        "CMUX_AGENT_HOOK_ROUTE_SNAPSHOT"

    /// The PID of the process that ran a spooled hook, recorded by the spool
    /// producer so a later forwarder can apply ``hookAgentPID(environmentPID:invocationAgentPID:controllingTerminal:)``.
    public static let invokerPIDEnvironmentKey = "CMUX_AGENT_HOOK_INVOKER_PID"

    /// The largest payload accepted by the local delivery queue.
    public static let maximumPayloadBytes = 64 * 1_024

    /// The maximum time a queued hook waits for the app to acknowledge admission.
    public static let admissionResponseTimeoutSeconds: TimeInterval = 0.5

    /// The whole-command budget of a queued hook process. The response
    /// timeout bounds only socket waits; keychain lookups, stdin, and process
    /// work are not socket waits. Past this budget the hook answers with its
    /// neutral response itself, well inside ``declaredTimeoutSeconds``.
    public static let admissionWallClockSeconds: TimeInterval = 2

    /// The timeout declared to agent runtimes for queued hook processes.
    public static let declaredTimeoutSeconds = 5

    /// The declared queued-hook timeout in milliseconds for runtimes such as Codex.
    public static let declaredTimeoutMilliseconds = declaredTimeoutSeconds * 1_000

    /// Current and historical queued-hook timeouts recognized during launch replay.
    ///
    /// Older cmux builds generated 3- and 10-second Codex hook timeouts. Replay
    /// must continue to strip those cmux-owned prefixes as well as the current
    /// 5-second form.
    public static let recognizedTimeoutMilliseconds: Set<Int> = [
        declaredTimeoutMilliseconds,
        3_000,
        10_000,
    ]

    private static let genericQueuedSubcommands: Set<String> = [
        "session-start",
        "prompt-submit",
        "stop",
        "notification",
        "agent-response",
        "approval-response",
        "shell-exec",
        "shell-done",
        "shell-failed",
        "session-end",
        "session-finalize",
    ]

    private static let auxiliaryQueuedSubcommands: [String: Set<String>] = [
        "amp": ["title-update", "lifecycle"],
        "claude": ["pre-tool-use", "post-tool-use", "push-notification", "feed"],
        "codex": ["pre-tool-use", "post-tool-use"],
        // OMP and Pi run subagents headless inside the parent's process, so a
        // child has no live bound process of its own. These lifecycle-only
        // events attribute to the existing parent record and never affect the
        // agent's next decision.
        "omp": ["subagent-start", "subagent-stop"],
        "pi": ["subagent-start", "subagent-stop"],
    ]

    /// Creates the shared queued-delivery policy.
    public init() {}

    /// Returns the environment key used to preserve an agent process identity.
    ///
    /// - Parameter agentName: The agent's normalized or display name.
    /// - Returns: An ASCII environment variable such as `CMUX_CLAUDE_PID`.
    public func pidEnvironmentVariable(agentName: String) -> String {
        let component = agentName.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]",
            with: "_",
            options: .regularExpression
        )
        return "CMUX_\(component)_PID"
    }

    /// Reports whether an agent event is safe to acknowledge before delivery.
    ///
    /// - Parameters:
    ///   - agent: The agent integration name.
    ///   - subcommand: The cmux hook subcommand.
    /// - Returns: `true` only for non-decision lifecycle, status, or known
    ///   wrapper-owned auxiliary events.
    public func supportsQueuedDelivery(agent: String, subcommand: String) -> Bool {
        let normalizedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSubcommand = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAgent.isEmpty,
              normalizedAgent.utf8.count <= 128,
              !normalizedAgent.contains("\0"),
              !normalizedSubcommand.isEmpty,
              normalizedSubcommand.utf8.count <= 64,
              !normalizedSubcommand.contains("\0") else {
            return false
        }
        if Self.genericQueuedSubcommands.contains(normalizedSubcommand) {
            return true
        }
        return Self.auxiliaryQueuedSubcommands[normalizedAgent]?.contains(normalizedSubcommand) == true
    }

    /// Chooses the agent process that owns one hook invocation.
    ///
    /// - Parameters:
    ///   - environmentPID: The agent PID exported in the hook's environment.
    ///   - invocationAgentPID: The nearest non-shell ancestor of the hook
    ///     process, which is the agent that ran the hook.
    ///   - controllingTerminal: Returns a live process's controlling terminal
    ///     device, or `nil` when the process has none or no longer exists.
    /// - Returns: The PID whose terminal identifies the hook's pane.
    ///
    /// The exported PID is inherited by everything the agent starts, so a
    /// second agent launched outside the wrapper (a fork in a tmux pane, a
    /// shell started from the first agent) carries the first agent's PID.
    /// When that PID is alive on a different terminal than the agent that ran
    /// the hook, it names another pane, and the hook's own agent wins. On the
    /// same terminal, or without terminal evidence, the exported PID is kept:
    /// a launcher shim may export its own PID while the agent runs as its child.
    public func hookAgentPID(
        environmentPID: Int?,
        invocationAgentPID: Int?,
        controllingTerminal: (Int) -> Int64?
    ) -> Int? {
        let invocationAgentPID = invocationAgentPID.flatMap { $0 > 1 ? $0 : nil }
        guard let environmentPID, environmentPID > 0 else {
            return invocationAgentPID
        }
        guard let invocationAgentPID,
              invocationAgentPID != environmentPID,
              let invocationTerminal = controllingTerminal(invocationAgentPID),
              let environmentTerminal = controllingTerminal(environmentPID),
              invocationTerminal != environmentTerminal else {
            return environmentPID
        }
        return invocationAgentPID
    }
}
