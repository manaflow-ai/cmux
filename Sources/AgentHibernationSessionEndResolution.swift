import Foundation

@MainActor
extension TerminalController {
    /// Reports whether a SessionEnd hook belongs to a pre-signaled, exact
    /// hibernation process generation.
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
        )
        return .ok(["preserve": preserve])
    }
}
