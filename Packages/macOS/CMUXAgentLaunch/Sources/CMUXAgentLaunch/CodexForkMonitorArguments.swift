/// Builds the arguments forwarded to a detached Codex fork monitor.
public struct CodexForkMonitorArguments: Sendable {
    /// Creates a stateless argument builder.
    public init() {}

    /// Preserves the parent-session claim and optional launch ownership values.
    public func make(environment: [String: String]) -> [String] {
        guard let forkParent = environment["CMUX_AGENT_FORK_PARENT_SESSION_ID"],
              !forkParent.isEmpty else { return [] }
        var arguments = ["--fork-parent", forkParent]
        if let launchID = environment["CMUX_AGENT_FORK_LAUNCH_ID"], !launchID.isEmpty {
            arguments += ["--fork-launch-id", launchID]
        }
        if let ownerPID = environment["CMUX_CODEX_PID"], !ownerPID.isEmpty {
            arguments += ["--fork-owner-pid", ownerPID]
        }
        return arguments
    }
}
