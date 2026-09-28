import CmuxFoundation
import Foundation

extension CmuxTopProcessSnapshot {
    /// Children an agent starts within this many seconds of its own start (MCP
    /// servers, launch hooks) are its baseline and do not count as work.
    static let agentBackgroundWorkBaselineSeconds: Int64 = 30

    private static let shellProcessNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "pwsh", "elvish", "xonsh",
    ]

    /// Descendants of `agentRootPIDs` that are shells the agent started after
    /// its launch baseline. Agents run tool commands through a shell, so a live
    /// late shell is a background command, a Monitor or watch loop, or a
    /// subagent's shell still doing work. Terminating the agent would kill it.
    /// Unknown start times never count as work; the scope's identity checks
    /// already refuse panes without complete identities.
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
