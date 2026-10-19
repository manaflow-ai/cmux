import CmuxFoundation
import Darwin
import Foundation

@MainActor
extension TerminalController {
    /// This app process's own generation. Local terminals are children of this
    /// process, so no agent running in one can have started before it.
    nonisolated private static let appProcessIdentity = AgentPIDProcessIdentity(pid: getpid())

    /// Reports whether a SessionEnd hook must leave the session's resume state
    /// in place: the hook belongs to a pre-signaled, exact hibernation process
    /// generation, or to a local agent that started before this app launched.
    ///
    /// The second case is an agent the previous app instance's quit killed,
    /// whose spooled SessionEnd this instance drains after restoring the panel
    /// with the same surface ID. Applying it would clear the restored resume
    /// binding (https://github.com/manaflow-ai/cmux/issues/21226). A process
    /// that is still running (for example under a tmux server that outlived
    /// the quit) reports its own exit, so only an exited generation qualifies.
    func v2AgentHibernationSessionEnd(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let surfaceID = v2UUID(params, "surface_id"),
              let sessionID = params["session_id"] as? String,
              let processID = v2StrictInt(params, "pid"),
              processID > 0,
              let processID32 = pid_t(exactly: processID),
              let startSeconds = v2StrictInt(params, "pid_start_seconds"),
              let startMicroseconds = v2StrictInt(params, "pid_start_microseconds"),
              let startSeconds64 = Int64(exactly: startSeconds),
              let startMicroseconds64 = Int64(exactly: startMicroseconds) else {
            return .ok(["preserve": false])
        }
        let identity = AgentPIDProcessIdentity(
            pid: processID32,
            startSeconds: startSeconds64,
            startMicroseconds: startMicroseconds64
        )
        let preserve = AgentHibernationController.shared.shouldPreserveSessionEnd(
            workspaceID: workspaceID,
            panelID: surfaceID,
            sessionID: sessionID,
            processIdentity: identity
        ) || (params["local_process"] as? Bool == true
            && Self.appProcessIdentity.map(identity.started(before:)) == true
            && AgentPIDProcessIdentity(pid: processID32) != identity)
        return .ok(["preserve": preserve])
    }
}
