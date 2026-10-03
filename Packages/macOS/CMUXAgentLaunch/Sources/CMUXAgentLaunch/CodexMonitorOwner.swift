import Foundation

/// Owns the launch-specific claims that a detached Codex monitor needs in
/// order to associate a fork with its parent process.
public struct CodexMonitorOwner {
    private let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func forkMonitorArguments() -> [String] {
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
