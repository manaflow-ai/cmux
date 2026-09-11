import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import Foundation

/// An immutable Feed handoff. JSON normalization happens on the journal worker.
struct AgentFeedSemanticInput: Sendable {
    let event: WorkstreamEvent
    let agentKey: String
    var notification: AgentJournalNotification? = nil
    var requestID: String? = nil
    var workspaceID: UUID? = nil
    var surfaceID: UUID? = nil
    var resolvesRequest = false

    var sessionID: String {
        let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: event.source, rawValue: event.sessionId)
        return FeedWorkstreamIdentifier(rawValue: canonical)?.sessionID ?? event.sessionId
    }

    func draft() -> AgentJournalEventDraft? {
        let extra = event.extraFieldsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let mapper = AgentSemanticEventMapper()
        let resolved = resolvesRequest || event.hookEventName == .postToolUse
        let kind: AgentJournalEventKind
        if resolved {
            kind = .attentionResolved
        } else {
            switch event.hookEventName {
            case .askUserQuestion: kind = .questionRequested
            case .exitPlanMode: kind = .planReviewRequested
            default: kind = mapper.kind(source: event.source, nativeEvent: event.hookEventName.rawValue)
            }
        }
        let nativeRequest = ["tool_use_id", "tool_call_id", "request_id", "agent_id"]
            .compactMap { extra[$0] as? String }.first
        let identity = nativeRequest ?? ((notification != nil || resolvesRequest) ? (requestID ?? event.requestId) : nil)
        if notification == nil, !resolved,
           ![.sessionStarted, .turnStarted, .sessionEnded, .childSpawned, .childCompleted, .childFailed].contains(kind) {
            return nil
        }
        guard !resolved || identity != nil,
              let workspace = workspaceID?.uuidString ?? event.workspaceId,
              let surface = surfaceID?.uuidString ?? event.surfaceId else { return nil }
        let occurred = (extra["occurred_at_ms"] as? NSNumber)
            .flatMap { $0.int64Value >= 0 ? $0.int64Value : nil }
        return AgentJournalEventDraft(kind: kind,
            occurredAtMs: resolvesRequest ? Int64(Date().timeIntervalSince1970 * 1000)
                : occurred ?? Int64(event.receivedAt.timeIntervalSince1970 * 1000),
            source: event.source, agentKey: agentKey,
            sessionId: sessionID, workspaceId: workspace, surfaceId: surface,
            pendingWork: resolvesRequest,
            nativeEvent: event.hookEventName.rawValue, declaredPhase: resolved ? .running : nil,
            attention: AgentAttentionContext(eventIdentity: extra["event_id"] as? String,
                turnIdentity: extra["turn_id"] as? String, requestIdentity: identity, notification: notification))
    }
}
