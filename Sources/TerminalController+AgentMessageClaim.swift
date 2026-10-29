import CmuxAgentJournal
import CmuxControlSocket
import Foundation

/// Claims queued agent messages after validating a supplied runtime owner.
extension TerminalController {
    /// Used by synchronous hooks (prompt submit, Codex stop): hands over every
    /// queued message for the caller's surface.
    nonisolated func agentMessageClaim(params: [String: Any]) async -> V2CallResult {
        guard let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]) else {
            return Self.agentMessageMissingSurface()
        }
        if let rawPID = params["agent_pid"] as? Int,
           let pid = pid_t(exactly: rawPID) {
            let isCurrentAgent = await MainActor.run {
                guard let target = AppDelegate.shared?.liveAgentDeliveryTarget(forAgentPID: pid) else {
                    return false
                }
                guard target.surfaceId.uuidString == surfaceId else { return false }
                return AppDelegate.shared?.liveKiroAgentProcessMatchesSurface(
                    pid: pid,
                    surfaceID: target.surfaceId
                ) == true
            }
            guard isCurrentAgent else {
                return .ok(["messages": [], "text": ""])
            }
        }
        let store = AgentMessageCenter.store
        if params["mark_delivered_read"] as? Bool == true {
            store.markPreviouslyDeliveredRead(recipientSurfaceId: surfaceId)
        }
        let via = Self.agentMessageTrimmed(params["via"]) ?? "hook"
        let messages: [AgentMessage]
        var leaseID: String?
        if params["defer_delivery"] as? Bool == true {
            guard let pollerKey = Self.agentMessageTrimmed(params["poller_key"]),
                  let deferred = store.deferredMessages(
                      recipientSurfaceId: surfaceId,
                      pollerKey: pollerKey,
                      limit: .max
                  ) else {
                return .ok(["status": "superseded", "messages": [], "text": ""])
            }
            messages = deferred.messages
            leaseID = deferred.id.isEmpty ? nil : deferred.id
        } else {
            messages = store.claimQueued(recipientSurfaceId: surfaceId, via: via)
        }
        var payload: [String: Any] = [
            "messages": messages.map(AgentMessageCenter.payload),
            "text": messages.agentPromptText,
        ]
        if let leaseID { payload["lease_id"] = leaseID }
        return .ok(payload)
    }
}
