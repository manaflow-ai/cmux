import CmuxFoundation
import Foundation

extension CmuxTopProcessSnapshot {
    /// Children an agent starts within this many seconds of its own start (MCP
    /// servers, launch hooks) are its baseline and do not count as work.
    static let agentBackgroundWorkBaselineSeconds: Int64 = 30

    private static let shellProcessNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "pwsh", "elvish", "xonsh",
    ]

    /// Direct children of `agentRootPIDs` that are shells the agent started
    /// after its launch baseline. Claude runs every tool command in a shell it
    /// spawns itself, so a live late child shell is a background command, a
    /// Monitor or watch loop, or a subagent's command still doing work, and
    /// terminating the agent would kill it. Shells deeper in the tree (an MCP
    /// server's `sh -c` under node) are not agent work and do not count.
    /// Unknown start times never count; the scope's identity checks already
    /// refuse panes without complete identities.
    func agentBackgroundWorkProcessIDs(
        agentRootPIDs: Set<Int>,
        descendantProcessIDs: Set<Int>
    ) -> Set<Int> {
        let rootStarts = agentRootPIDs.compactMap { processesByPID[$0]?.processIdentity?.startSeconds }
        guard let agentStart = rootStarts.min() else { return [] }
        let baselineEnd = agentStart + Self.agentBackgroundWorkBaselineSeconds
        return descendantProcessIDs.filter { processID in
            guard !agentRootPIDs.contains(processID),
                  let process = processesByPID[processID],
                  agentRootPIDs.contains(process.parentPID),
                  let startSeconds = process.processIdentity?.startSeconds,
                  startSeconds > baselineEnd else {
                return false
            }
            return Self.isShellProcessName(process.name)
        }
    }

    static func isShellProcessName(_ name: String) -> Bool {
        var base = (name as NSString).lastPathComponent
        if base.hasPrefix("-") {
            base.removeFirst()
        }
        return shellProcessNames.contains(base)
    }
}

/// Helpers cmux's own agent integration runs beside an agent. A helper does
/// none of the agent's work and is useless without it, so hibernation stops it
/// with the agent instead of refusing the pane as running other work.
enum CmuxAgentHelperProcess {
    /// Each helper's argv after the cmux executable.
    ///
    /// `hooks claude inbox-wait` is the `asyncRewake` hook the Claude wrapper
    /// registers on SessionStart, Stop and StopFailure. Claude Code starts it
    /// detached, with no controlling terminal; it polls the app for this
    /// surface's agent messages and exits once its agent is gone.
    static let registeredArguments: [[String]] = [
        ["hooks", "claude", "inbox-wait"],
    ]

    /// Whether `arguments` run a registered helper for the given panel.
    static func isRegistered(
        _ arguments: CmuxTopProcessArguments,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Bool {
        guard let executable = arguments.arguments.first,
              (executable as NSString).lastPathComponent == "cmux",
              registeredArguments.contains(Array(arguments.arguments.dropFirst())) else {
            return false
        }
        return arguments.matchesCMUXScope(workspaceId: workspaceId, surfaceId: surfaceId)
    }
}
