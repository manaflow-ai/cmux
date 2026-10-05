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
        let declaredActivity = (extra["declared_activity"] as? String).flatMap(AgentSessionActivity.init(rawValue:))
        let declaredReason = (extra["declared_reason"] as? String).flatMap(AgentRuntimeReason.init(rawValue:))
        let declaredMode = mapper.mode(nativeMode: extra["declared_mode"] as? String ?? extra["execution_mode"] as? String)
        let nativeRequest = ["tool_use_id", "tool_call_id", "request_id", "agent_id"]
            .compactMap { extra[$0] as? String }.first
            ?? (event.source.lowercased() == "opencode" ? event.requestId : nil)
        let isToolActivity = event.hookEventName == .preToolUse
            || event.hookEventName == .postToolUse
            || event.hookEventName == .postToolUseFailure
        // A PostToolUse with an identity also resolves a pending approval. A
        // telemetry payload without one still proves the agent is working, but
        // must not clear an unrelated request.
        let resolved = resolvesRequest || (event.hookEventName == .postToolUse && nativeRequest != nil)
        let kind: AgentJournalEventKind
        if resolved {
            kind = .attentionResolved
        } else if isToolActivity {
            kind = .stateChanged
        } else {
            switch event.hookEventName {
            case .askUserQuestion: kind = .questionRequested
            case .exitPlanMode: kind = .planReviewRequested
            default: kind = mapper.kind(source: event.source, nativeEvent: event.hookEventName.rawValue, toolName: event.toolName)
            }
        }
        let identity = nativeRequest ?? ((notification != nil || resolvesRequest) ? (requestID ?? event.requestId) : nil)
        if notification == nil, !resolved, declaredActivity == nil, declaredMode == nil,
           ![.sessionStarted, .turnStarted, .turnCompleted, .idleObserved, .errorReported, .sessionEnded, .childSpawned, .childCompleted, .childFailed].contains(kind),
           !(kind == .stateChanged && isToolActivity) {
            return nil
        }
        guard !resolved || identity != nil,
              let workspace = workspaceID?.uuidString ?? event.workspaceId,
              let surface = surfaceID?.uuidString ?? event.surfaceId else { return nil }
        let occurred = (extra["occurred_at_ms"] as? NSNumber)
            .flatMap { $0.int64Value >= 0 ? $0.int64Value : nil }
        let generation = (extra["process_generation"] as? NSNumber).flatMap { $0.int64Value > 0 ? $0.uint64Value : nil }
        return AgentJournalEventDraft(eventId: extra["event_id"] as? String ?? UUID().uuidString, kind: kind,
            occurredAtMs: resolvesRequest ? Int64(Date().timeIntervalSince1970 * 1000)
                : occurred ?? Int64(event.receivedAt.timeIntervalSince1970 * 1000),
            source: event.source, agentKey: agentKey,
            sessionId: sessionID, workspaceId: workspace, surfaceId: surface,
            pendingWork: resolvesRequest || (extra["pending_work"] as? Bool ?? false),
            // Tool activity is a running assertion. It reopens a continuation
            // that has no UserPromptSubmit hook; older activity is rejected by
            // the reconciler's timestamp and turn-identity watermarks.
            nativeEvent: event.hookEventName.rawValue,
            declaredPhase: resolved && !resolvesRequest && extra["pending_work"] as? Bool == false
                ? .idle : ((resolvesRequest || isToolActivity) ? .running : nil),
            attention: AgentAttentionContext(eventIdentity: extra["event_id"] as? String,
                turnIdentity: extra["turn_id"] as? String, requestIdentity: identity, notification: notification),
            declaredActivity: declaredActivity, declaredReason: declaredReason, declaredMode: declaredMode, processGeneration: generation)
    }
}
