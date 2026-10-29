import CmuxAgentJournal
import CmuxControlSocket
import CmuxFoundation
import Foundation

/// Claims queued agent messages after validating a supplied runtime owner.
extension TerminalController {
    /// Used by synchronous hooks (prompt submit, Codex stop): hands over every
    /// queued message for the caller's surface.
    nonisolated func agentMessageClaim(params: [String: Any]) async -> V2CallResult {
        guard let surfaceId = Self.agentMessageSurfaceUUID(params["surface_id"]) else {
            return Self.agentMessageMissingSurface()
        }
        if params["agent_pid"] != nil {
            guard let rawPID = v2StrictIntAny(params["agent_pid"]),
                  rawPID > 0,
                  let pid = pid_t(exactly: rawPID) else {
                return .ok(["messages": [], "text": ""])
            }
            let evidence = await runSocketWorkerBlockingBody {
                agentDeliveryProcessEvidence(pid: pid, resolution: .corroborated)
            }
            guard let key = evidence.scopeCacheKey else {
                return .ok(["messages": [], "text": ""])
            }
            let identity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: Int64(key.startSeconds),
                startMicroseconds: Int64(key.startMicroseconds)
            )
            let isCurrentAgent = await MainActor.run {
                guard let appDelegate = AppDelegate.shared,
                      let target = appDelegate.liveAgentDeliveryTarget(for: evidence, resolution: .corroborated),
                      target.surfaceId.uuidString == surfaceId else { return false }
                return appDelegate.liveKiroAgentProcessMatchesSurface(identity: identity, surfaceID: target.surfaceId)
            }
            // The actor hop may wait behind a UI turn. Validate the same birth
            // time again on the worker before consuming any queued message.
            let currentIdentity = await runSocketWorkerBlockingBody { AgentPIDProcessIdentity(pid: pid) }
            guard isCurrentAgent, currentIdentity == identity else {
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
